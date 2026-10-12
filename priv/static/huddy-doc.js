// Huddy documents: render a document's Markdown in the browser with marked,
// sanitized by DOMPurify. Relative links and images are resolved against the
// document's own files. Without this script the page shows the Markdown.
(() => {
  "use strict";
  const src = document.getElementById("doc-src");
  const out = document.getElementById("doc-body");
  if (!src || !out || !window.marked || !window.DOMPurify) return;

  const base = src.dataset.base; // e.g. "/docs/12-design-notes"
  const here = src.dataset.path || "index.md";
  const files = new Set((src.dataset.files || "").split("\n").filter(Boolean));
  const dir = here.includes("/") ? here.slice(0, here.lastIndexOf("/") + 1) : "";

  const decode = (s) => {
    try {
      return decodeURIComponent(s);
    } catch (_) {
      return s;
    }
  };
  // A path inside the document, or null if the reference leaves it.
  const resolve = (ref) => {
    const parts = [];
    for (const seg of (dir + decode(ref)).split("/")) {
      if (seg === "" || seg === ".") continue;
      if (seg === "..") {
        if (!parts.length) return null;
        parts.pop();
      } else parts.push(seg);
    }
    return parts.join("/");
  };
  const isRelative = (url) =>
    !/^[a-z][a-z0-9+.-]*:/i.test(url) && !url.startsWith("/") && !url.startsWith("#");
  const fileUrl = (path) =>
    base + "/files/" + path.split("/").map(encodeURIComponent).join("/");
  // [path, "#fragment"]; a query string is dropped.
  const split = (url) => {
    const h = url.indexOf("#");
    const hash = h < 0 ? "" : url.slice(h);
    const path = h < 0 ? url : url.slice(0, h);
    const q = path.indexOf("?");
    return [q < 0 ? path : path.slice(0, q), hash];
  };

  DOMPurify.addHook("afterSanitizeAttributes", (node) => {
    if (node.tagName === "IMG" && node.hasAttribute("src")) {
      const raw = node.getAttribute("src");
      if (isRelative(raw)) {
        const path = resolve(split(raw)[0]);
        if (path !== null && files.has(path)) node.setAttribute("src", fileUrl(path));
        else node.removeAttribute("src");
      }
      node.setAttribute("loading", "lazy");
    } else if (node.tagName === "A" && node.hasAttribute("href")) {
      const raw = node.getAttribute("href");
      if (isRelative(raw)) {
        const [ref, hash] = split(raw);
        const path = resolve(ref);
        if (path !== null && files.has(path)) {
          node.setAttribute(
            "href",
            /\.(md|markdown)$/i.test(path)
              ? base + (path === "index.md" ? "" : "?path=" + encodeURIComponent(path)) + hash
              : fileUrl(path),
          );
        } else node.removeAttribute("href");
      } else if (/^https?:/i.test(raw)) {
        node.setAttribute("target", "_blank");
        node.setAttribute("rel", "noopener nofollow");
      }
    }
  });

  const html = window.marked.parse(src.textContent, { gfm: true, async: false });
  out.innerHTML = DOMPurify.sanitize(html, {
    FORBID_TAGS: ["style", "form", "button", "textarea", "select", "iframe"],
    FORBID_ATTR: ["style"],
  });

  // The page already shows the title: drop a leading "# Title" that repeats it.
  const first = out.firstElementChild;
  if (first && first.tagName === "H1" && first.textContent.trim() === (src.dataset.title || "").trim())
    first.remove();

  // Anchors for headings, so "#section" links work.
  const used = new Set();
  out.querySelectorAll("h1, h2, h3, h4, h5, h6").forEach((h) => {
    let slug = h.textContent.trim().toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-|-$/g, "") || "section";
    while (used.has(slug)) slug += "-";
    used.add(slug);
    h.id = slug;
  });

  out.hidden = false;
  src.hidden = true;
  if (location.hash) document.getElementById(decode(location.hash.slice(1)))?.scrollIntoView();
})();
