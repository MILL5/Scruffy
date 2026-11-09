"use strict";

// This small example is entirely in memory. It does not access local files.
const examples = [
  { id: "video", name: "weekend-video.mov", path: "Movies / Weekend walks", bytes: 1200, category: "Large file", kind: "video" },
  { id: "notes", name: "travel-notes.zip", path: "Downloads / London", bytes: 420, category: "Old download", kind: "archive" },
  { id: "copy", name: "london-photos.zip", path: "Downloads / zip-archives", bytes: 310, category: "Duplicate copy", kind: "archive" },
  { id: "original", name: "london-photos.zip", path: "Documents / Originals", bytes: 310, category: "Protected original", kind: "archive", keeper: true },
  { id: "cache", name: "browser-cache.data", path: "Library / Caches", bytes: 40, category: "Browser cache", kind: "cache" }
].sort((a, b) => b.bytes - a.bytes || a.path.localeCompare(b.path));

const query = document.querySelector("#demo-query");
const rows = document.querySelector("#example-files");
const all = document.querySelector("#select-matches");
const summary = document.querySelector("#selection-summary");
const count = document.querySelector("#match-count");
const clear = document.querySelector("#clear-selection");
const selected = new Set();
let visible = examples;

function matches(file, words) {
  const text = `${file.name} ${file.path}`.toLocaleLowerCase();
  return words.every(word => text.includes(word));
}

function fileIcon(kind) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 30 34");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("class", `file-symbol ${kind}-symbol`);
  const shape = document.createElementNS(svg.namespaceURI, "path");
  shape.setAttribute("d", "M7 2h11l7 7v21a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zm11 0v8h7");
  svg.append(shape);
  const detail = document.createElementNS(svg.namespaceURI, "path");
  detail.setAttribute("d", kind === "video" ? "m12 15 7 5-7 5z" : kind === "cache" ? "M10 18h10m-10 5h10" : "M15 12v3m0 3v3m0 3v3");
  svg.append(detail);
  return svg;
}

function render() {
  const words = query.value.toLocaleLowerCase().trim().split(/\s+/u).filter(Boolean);
  visible = examples.filter(file => matches(file, words));
  rows.replaceChildren();

  for (const file of visible) {
    const row = document.createElement("div");
    row.className = `example-file${selected.has(file.id) ? " is-selected" : ""}`;
    const checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.checked = selected.has(file.id);
    checkbox.disabled = !!file.keeper;
    checkbox.setAttribute("aria-label", file.keeper ? `${file.name}, protected original` : `Select ${file.name} in example`);
    checkbox.addEventListener("change", () => {
      if (checkbox.checked) selected.add(file.id); else selected.delete(file.id);
      render();
      rows.querySelector(`[data-file-id="${file.id}"]`)?.focus();
    });
    checkbox.dataset.fileId = file.id;
    const checkLabel = document.createElement("label");
    checkLabel.className = "file-check";
    checkLabel.append(checkbox);
    const copy = document.createElement("div");
    copy.className = "file-copy";
    const name = document.createElement("span");
    name.className = "file-name";
    name.textContent = file.name;
    const path = document.createElement("span");
    path.className = "file-path";
    path.textContent = file.path;
    copy.append(name, path);
    const size = document.createElement("div");
    size.className = "file-size";
    size.textContent = file.bytes >= 1000 ? `${(file.bytes / 1000).toFixed(1)} GB` : `${file.bytes} MB`;
    if (file.keeper) {
      const protectedLabel = document.createElement("span");
      protectedLabel.className = "keeper-tag";
      protectedLabel.textContent = "Original stays";
      size.append(protectedLabel);
    }
    row.append(checkLabel, fileIcon(file.kind), copy, size);
    rows.append(row);
  }

  if (!visible.length) {
    const empty = document.createElement("p");
    empty.className = "empty-preview";
    empty.textContent = "No example files match. Try london zip or clear your search.";
    rows.append(empty);
  }

  const eligible = visible.filter(file => !file.keeper);
  const checked = eligible.filter(file => selected.has(file.id)).length;
  all.disabled = !eligible.length;
  all.checked = eligible.length > 0 && checked === eligible.length;
  all.indeterminate = checked > 0 && checked < eligible.length;
  count.textContent = `${visible.length} ${visible.length === 1 ? "match" : "matches"}`;
  summary.textContent = `${selected.size} selected in this example`;
  clear.disabled = !selected.size;
}

query.addEventListener("input", render);
document.querySelector("#preview-form").addEventListener("submit", event => event.preventDefault());
document.querySelector("#clear-search").addEventListener("click", () => { query.value = ""; render(); query.focus(); });
document.querySelectorAll("[data-query]").forEach(button => button.addEventListener("click", () => { query.value = button.dataset.query; render(); query.focus(); }));
all.addEventListener("change", () => { for (const file of visible) { if (!file.keeper) { if (all.checked) selected.add(file.id); else selected.delete(file.id); } } render(); });
clear.addEventListener("click", () => { selected.clear(); render(); });
render();
