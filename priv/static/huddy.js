// Huddy: live zone swaps over SSE, fetch()-upgraded forms, notifications.
// The page works without this script, minus live updates.
(() => {
  "use strict";

  // Forms marked data-fetch post in the background (the server answers 204).
  document.addEventListener("submit", async (ev) => {
    const form = ev.target;
    if (!(form instanceof HTMLFormElement) || !form.hasAttribute("data-fetch")) return;
    ev.preventDefault();
    try {
      const res = await fetch(form.action, {
        method: "POST",
        body: new URLSearchParams(new FormData(form)),
        headers: { "x-huddy-fetch": "1" },
        credentials: "same-origin",
      });
      if (!res.ok) form.submit();
    } catch (_) {
      form.submit();
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

  // Don't swap a zone the user is typing in or has a <details> open in;
  // keep it pending and apply when they're done.
  const pending = new Map();
  const busy = (el) => {
    const active = document.activeElement;
    const typing =
      active && el.contains(active) && active.matches("input, textarea, select");
    return typing || el.querySelector("details[open]") !== null;
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
      if ("Notification" in window && Notification.permission === "granted") {
        const note = new Notification(n.title, { body: n.body, tag: n.tag });
        note.onclick = () => {
          window.focus();
          location.hash = n.tag.replace("huddy-d", "i");
        };
      }
    } catch (_) {}
  });
  es.addEventListener("reload", () => location.reload());
})();
