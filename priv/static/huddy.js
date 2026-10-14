// Huddy: live zone swaps over SSE, fetch()-upgraded forms, notifications.
// The page works without this script, minus live updates.
(() => {
  "use strict";

  // Forms marked data-fetch post in the background (the server answers 204).
  document.addEventListener("submit", async (ev) => {
    const form = ev.target;
    if (!(form instanceof HTMLFormElement) || !form.hasAttribute("data-fetch")) return;
    ev.preventDefault();
    // the clicked button's name/value (e.g. a decision option) goes along,
    // also in browsers whose FormData ignores the submitter
    const button = ev.submitter;
    const data = new FormData(form);
    if (button && button.name) data.set(button.name, button.value);
    // a normal post, keeping the clicked button's value
    const fallback = () => {
      if (button && button.name) {
        const input = document.createElement("input");
        input.type = "hidden";
        input.name = button.name;
        input.value = button.value;
        form.appendChild(input);
      }
      form.submit();
    };
    let res;
    try {
      res = await fetch(form.action, {
        method: "POST",
        body: new URLSearchParams(data),
        headers: { "x-huddy-fetch": "1" },
        credentials: "same-origin",
      });
    } catch (_) {
      fallback();
      return;
    }
    if (res.redirected) {
      // signed out: the post went to the login page and nothing was saved
      alert("You're signed out, so this wasn't saved. Sign in again (your text is still here).");
      return;
    }
    if (res.status === 400 || res.status === 429) {
      // show the server's reason (e.g. the item closed meanwhile)
      alert((await res.text()).replace(/^Bad request: /, "") || "That didn't work.");
      return;
    }
    if (res.status !== 204) {
      fallback();
      return;
    }
    if (form.hasAttribute("data-reset")) {
      // clear it and close its <details>, so the held-back zone swap lands
      form.reset();
      form.closest("details")?.removeAttribute("open");
    }
  });

  const board = document.querySelector(".board[data-events]");
  if (!board) return;

  const baseTitle = document.title.replace(/^\(\d+\) /, "");
  const setTitle = () => {
    const el = document.getElementById("count");
    const n = el ? parseInt(el.dataset.count || "0", 10) : 0;
    document.title = (n > 0 ? `(${n}) ` : "") + baseTitle;
  };

  // Don't swap a zone the user is typing in or has a <details> open in
  // (other than a thread's read-only "N earlier"); keep it pending and
  // apply when they're done.
  const pending = new Map();
  const busy = (el) => {
    const active = document.activeElement;
    const typing =
      active && el.contains(active) && active.matches("input, textarea, select");
    return typing || el.querySelector("details[open]:not(.earlier)") !== null;
  };
  const apply = (html) => {
    const t = document.createElement("template");
    t.innerHTML = html.trim();
    const next = t.content.firstElementChild;
    if (!next || !next.id) return;
    const current = document.getElementById(next.id);
    if (!current) return;
    if (busy(current)) {
      pending.set(next.id, html);
      return;
    }
    pending.delete(next.id);
    current.replaceWith(next);
    if (next.id === "zone-header") {
      setTitle();
      setupNotify();
      setLive(true);
    }
  };
  const flush = () => setTimeout(() => [...pending.values()].forEach(apply), 50);
  document.addEventListener("focusout", flush);
  document.addEventListener("toggle", flush, true);

  const setLive = (on) => {
    const el = document.getElementById("live");
    if (el) el.classList.toggle("on", on);
  };

  const setupNotify = () => {
    const btn = document.getElementById("notify-toggle");
    if (!btn || !("Notification" in window)) return;
    btn.hidden = Notification.permission !== "default";
    btn.onclick = async () => {
      await Notification.requestPermission();
      btn.hidden = Notification.permission !== "default";
    };
  };
  setupNotify();

  // Through the service worker where there is one: installed apps (and
  // Android, which has no Notification constructor) only show those.
  const notify = async (n) => {
    const hash = "#" + n.tag.replace("huddy-d", "i");
    const options = { body: n.body, tag: n.tag, icon: "/static/icon-192.png", data: { hash } };
    const reg = "serviceWorker" in navigator && (await navigator.serviceWorker.getRegistration());
    if (reg) return reg.showNotification(n.title, options);
    const note = new Notification(n.title, options);
    note.onclick = () => {
      window.focus();
      location.hash = hash;
    };
  };
  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.addEventListener("message", (e) => {
      if (e.data && e.data.huddy === "show") location.hash = e.data.hash;
    });
  }

  const url = board.dataset.events;
  const sep = url.includes("?") ? "&" : "?";
  const es = new EventSource(url + sep + "boot=" + encodeURIComponent(board.dataset.boot || ""));
  es.onopen = () => setLive(true);
  es.onerror = () => setLive(false);
  es.addEventListener("swap", (e) => apply(e.data));
  es.addEventListener("notify", (e) => {
    try {
      const n = JSON.parse(e.data);
      if (typeof n.count === "number") {
        const el = document.getElementById("count");
        if (el) el.dataset.count = String(n.count);
        setTitle();
      }
      if ("Notification" in window && Notification.permission === "granted") notify(n).catch(() => {});
    } catch (_) {}
  });
  es.addEventListener("reload", () => location.reload());
})();
