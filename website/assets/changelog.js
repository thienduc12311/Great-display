// Renders CHANGELOG.md (Keep a Changelog format) as release notes.
// The site build copies CHANGELOG.md next to index.html, so the notes on the
// website always match the ones published with each GitHub release.

(function () {
  const REPO = "https://github.com/thienduc12311/Great-display";

  function escapeHTML(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  function inline(md) {
    let s = escapeHTML(md);
    const codes = [];
    s = s.replace(/`([^`]+)`/g, (_, c) => { codes.push(c); return `\u0000${codes.length - 1}\u0000`; });
    s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    s = s.replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+|[^)\s:]+)\)/g, (_, text, href) => {
      const url = /^https?:/.test(href) ? href : `${REPO}/blob/main/${href}`;
      return `<a href="${url}">${text}</a>`;
    });
    return s.replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${codes[+i]}</code>`);
  }

  /** Parses the changelog into [{version, date, intro, sections: [{title, items}]}]. */
  function parse(md) {
    const releases = [];
    const links = {};
    // `item` is the bullet being read; `gap` is set after a blank line inside
    // it, so an indented paragraph that follows still belongs to that bullet.
    let release = null, section = null, item = null, gap = false;
    for (const raw of md.split(/\r?\n/)) {
      const line = raw.replace(/\s+$/, "");
      let m;
      if ((m = line.match(/^\[([^\]]+)\]:\s*(\S+)/))) { links[m[1]] = m[2]; item = null; continue; }
      if ((m = line.match(/^## \[([^\]]+)\](?:\s*-\s*(.+))?/))) {
        release = { version: m[1], date: m[2] || "", intro: [], sections: [] };
        releases.push(release); section = null; item = null; continue;
      }
      if (!release) continue;
      if ((m = line.match(/^### (.+)/))) { section = { title: m[1], items: [] }; release.sections.push(section); item = null; continue; }
      if ((m = line.match(/^[-*] (.+)/))) {
        if (!section) { section = { title: "", items: [] }; release.sections.push(section); }
        item = m[1]; gap = false; section.items.push(item); continue;
      }
      if (line.trim() === "") { if (item !== null) gap = true; continue; }
      if (item !== null && /^\s+/.test(line) && section) {
        section.items[section.items.length - 1] += (gap ? "\n\n" : " ") + line.trim();
        gap = false;
        continue;
      }
      item = null; gap = false;
      if (!section) release.intro.push(line.trim());
    }
    for (const r of releases) r.link = links[r.version];
    return releases.filter((r) => r.version.toLowerCase() !== "unreleased" || r.sections.some((s) => s.items.length));
  }

  function formatDate(iso) {
    const d = new Date(iso + "T00:00:00Z");
    if (isNaN(d)) return iso;
    return d.toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" });
  }

  function render(release, opts) {
    const unreleased = release.version.toLowerCase() === "unreleased";
    const level = opts.headingLevel || 2;
    const id = unreleased ? "unreleased" : "v" + release.version;
    const title = unreleased ? "Coming next" : `Great Display ${release.version}`;
    let html = `<article class="release${opts.teaser ? " teaser" : ""}" id="${id}">`;
    html += `<div class="release-head"><h${level}>${escapeHTML(title)}</h${level}>`;
    if (release.date) html += `<time datetime="${escapeHTML(release.date)}">${formatDate(release.date)}</time>`;
    if (opts.latest && !unreleased) html += `<span class="pill">Latest</span>`;
    if (unreleased) html += `<span class="pill gray">In development</span>`;
    html += `</div>`;
    if (release.intro.length) html += `<p class="release-intro">${inline(release.intro.join(" "))}</p>`;
    for (const s of release.sections) {
      let items = s.items;
      if (opts.teaser) items = items.slice(0, opts.teaser);
      if (s.title) html += `<h4>${escapeHTML(s.title)}</h4>`;
      html += `<ul>${items.map((i) => `<li>${i.split("\n\n").map(inline).join('<span class="li-para"></span>')}</li>`).join("")}</ul>`;
    }
    html += `<div class="release-actions">`;
    if (opts.teaser) {
      html += `<a class="btn secondary" href="release-notes.html">Read the full release notes</a>`;
    } else if (!unreleased) {
      html += `<a class="btn" href="${REPO}/releases/tag/v${encodeURIComponent(release.version)}">Download ${escapeHTML(release.version)}</a>`;
      if (release.link) html += `<a class="btn ghost" href="${release.link}">View on GitHub ›</a>`;
    }
    html += `</div></article>`;
    return html;
  }

  async function load() {
    const response = await fetch("CHANGELOG.md", { cache: "no-cache" });
    if (!response.ok) throw new Error(response.status);
    return parse(await response.text());
  }

  function fallback(el) {
    el.innerHTML = `<div class="release"><p class="release-intro">The release notes could not be loaded here.
      Read them in <a href="${REPO}/blob/main/CHANGELOG.md">CHANGELOG.md</a> or on the
      <a href="${REPO}/releases">Releases page</a>.</p></div>`;
  }

  window.GDChangelog = {
    /** Fills `el` with every release. */
    async renderAll(el) {
      try {
        const releases = await load();
        const firstReleased = releases.findIndex((r) => r.version.toLowerCase() !== "unreleased");
        el.innerHTML = releases.map((r, i) => render(r, { latest: i === firstReleased })).join("");
        const toc = document.querySelector("[data-release-toc]");
        if (toc) {
          toc.innerHTML = releases.map((r) => {
            const unreleased = r.version.toLowerCase() === "unreleased";
            return `<a class="chip" href="#${unreleased ? "unreleased" : "v" + r.version}">${unreleased ? "Next" : escapeHTML(r.version)}</a>`;
          }).join("");
        }
        if (location.hash) document.getElementById(decodeURIComponent(location.hash.slice(1)))?.scrollIntoView();
      } catch (e) { fallback(el); }
    },
    /** Fills `el` with a short summary of the newest release and sets version labels. */
    async renderLatest(el) {
      try {
        const releases = (await load()).filter((r) => r.version.toLowerCase() !== "unreleased");
        if (!releases.length) throw new Error("no releases");
        const latest = releases[0];
        if (el) el.innerHTML = render(latest, { latest: true, teaser: 8, headingLevel: 3 });
        document.querySelectorAll("[data-version]").forEach((n) => { n.textContent = latest.version; });
        document.querySelectorAll("[data-version-date]").forEach((n) => { n.textContent = formatDate(latest.date); });
      } catch (e) { if (el) fallback(el); }
    },
  };
})();
