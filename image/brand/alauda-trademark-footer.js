/* Append the trademark declaration (verbatim) as plain text nodes inside SonarQube's own disclaimer span — one <span>, one paragraph, one visual block. Logos are replaced at build time by apply_brand.py. Do not translate or reword the trademark text. */
(function () {
  var L1 = 'SonarQube\u00AE and SonarSource\u00AE are registered trademarks of SonarSource S.A.';
  var L2 = 'Alauda is an independent vendor. This product is not affiliated with, endorsed by, or sponsored by SonarSource S.A. All trademarks are the property of their respective owners and are used here for identification purposes only.';
  var SPAN_MARK = 'data-alauda-tm-appended';

  function restoreRow() {
    // Undo any earlier centered-stack tweak so the original left/right row layout is preserved.
    var footer = document.getElementById('footer');
    if (!footer) return;
    var row = footer.querySelector('.sw-flex.sw-justify-between');
    if (!row) return;
    ['flexDirection', 'justifyContent', 'alignItems', 'gap', 'textAlign'].forEach(function (k) { row.style[k] = ''; });
    row.style.alignItems = 'flex-start';
    // Sweep any stale separate trademark notes from earlier iterations.
    row.querySelectorAll('.alauda-trademark-notice').forEach(function (n) { n.remove(); });
  }

  function ensureInlineAppend() {
    var brand = document.querySelector('[data-component="global-footer-branding"]');
    if (!brand) return;
    // Restore default sizing so the sentence wraps naturally when it grows longer.
    brand.style.display = '';
    var span = brand.querySelector('span');
    if (!span) return;
    if (span.hasAttribute(SPAN_MARK)) return;
    if (span.classList.contains('sw-text-nowrap')) span.classList.remove('sw-text-nowrap');
    // Append the two sentences as plain text nodes so the whole disclaimer lives inside a single <span>.
    span.appendChild(document.createTextNode(' ' + L1 + ' ' + L2));
    span.setAttribute(SPAN_MARK, '1');
  }

  function run() { restoreRow(); ensureInlineAppend(); }
  run();
  var mo = new MutationObserver(run);
  mo.observe(document.documentElement, { childList: true, subtree: true });
})();
