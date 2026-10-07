// スキルの一覧の画面。名前と説明の部分一致でカードを絞り込む。
// カードはサーバーが描いたものを使い、ここでは作らない（inbox_server.py の skills_page）。
// JavaScript が動かないときは、絞り込みの欄を出さずに全件を表示する。
(function () {
  "use strict";

  var box = document.getElementById("skill-filter");
  var input = document.getElementById("skill-q");
  var status = document.getElementById("skill-filter-status");
  var cards = document.querySelectorAll("#skill-cards .card.skill");
  if (!box || !input || !status || cards.length === 0) {
    return;
  }
  box.hidden = false;

  function apply() {
    var q = input.value.trim().toLowerCase();
    var shown = 0;
    cards.forEach(function (card) {
      var hit = q === "" || (card.getAttribute("data-search") || "").indexOf(q) !== -1;
      card.hidden = !hit;
      if (hit) {
        shown += 1;
      }
    });
    status.textContent = q === "" ? "" : cards.length + " 件中 " + shown + " 件を表示しています。";
  }

  input.addEventListener("input", apply);
})();
