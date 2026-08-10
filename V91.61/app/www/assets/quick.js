(function () {
  'use strict';
  if (new URLSearchParams(window.location.search).get('compact') === '1') document.documentElement.classList.add('yaku-compact');
  var ready = false;
  var busy = false;
  var explicitDirection = '';
  var artifact = null;
  var pollTimer = null;
  var revisionInFlight = false;
  var activeSourceSnapshot = '';

  function el(id) { return document.getElementById(id); }
  function update() {
    var text = el('quick-input').value;
    el('quick-count').textContent = Array.from(text).length.toLocaleString('ja-JP') + '字';
    el('quick-direction-summary').hidden = !text.trim() || !explicitDirection;
    el('quick-direction-choice').hidden = true;
    if (explicitDirection) el('quick-direction-label').textContent = explicitDirection === 'to_en' ? '英語に訳します' : '日本語に訳します';
    var submit = el('quick-submit');
    submit.textContent = !text.trim() ? '文章を入力してください' : explicitDirection === 'to_en' ? '英語の訳案を作る' : explicitDirection === 'to_jp' ? '日本語の訳案を作る' : '訳案を作る';
    submit.disabled = !text.trim() || !ready || busy;
    el('quick-input').readOnly = busy;
    ['quick-copy', 'quick-revise-open', 'quick-promote'].forEach(function (id) {
      var button = el(id); if (button) button.disabled = busy;
    });
    var reviseForm = el('quick-revise-form');
    var reviseInput = el('quick-revise-instruction');
    var reviseSubmit = el('quick-revise-submit');
    var reviseCancel = el('quick-revise-cancel');
    if (reviseForm) reviseForm.setAttribute('aria-busy', busy && revisionInFlight ? 'true' : 'false');
    if (reviseInput) reviseInput.readOnly = busy;
    if (reviseSubmit) reviseSubmit.disabled = busy;
    if (reviseCancel) reviseCancel.disabled = busy;
  }

  function showChoice(message) {
    var choice = el('quick-direction-choice');
    choice.hidden = false;
    el('quick-direction-help').textContent = message || '日本語と外国語が混ざっているため、自動で決められません。';
    YakuCommon.focus(choice.querySelector('[data-quick-direction]'));
  }

  function renderJob(label, progress) {
    el('quick-job').innerHTML = '<div class="job-loading"><div class="job-loading-inner"><div class="job-topline"><div class="job-phase">' + YakuCommon.escape(label || '訳案を作成中') + '</div><div class="job-percent">' + Math.round(progress || 0) + '%</div></div><div class="job-progress-line" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="' + Math.round(progress || 0) + '"><span class="job-progress-bar" style="width:' + Math.round(progress || 0) + '%"></span></div></div></div>';
  }

  function finish(data) {
    var wasRevision = revisionInFlight;
    revisionInFlight = false;
    var sourceStillMatches = el('quick-input').value.trim() === activeSourceSnapshot;
    activeSourceSnapshot = '';
    busy = false;
    el('quick-job').innerHTML = '';
    if (!sourceStillMatches) {
      artifact = null;
      el('quick-result').hidden = true;
      update();
      showError('文章が変わったため、受け取った訳案は表示していません。現在の文章でもう一度お試しください。');
      return;
    }
    artifact = data.artifact || null;
    if (!artifact || !artifact.translation) { showError('訳案を取得できませんでした。'); return; }
    var toEnglish = artifact.direction === 'to_en';
    el('quick-result-title').textContent = toEnglish ? '英語の訳案（未確認）' : '日本語の訳案（内容確認用）';
    el('quick-result-text').textContent = artifact.translation;
    el('quick-result-note').textContent = toEnglish ? '外部へ配布する資料に使う場合は、資料翻訳で1文ずつ確認してください。' : '内容確認用の訳案です。';
    var maskCount = Number(artifact.masked_count || 0);
    el('quick-mask-summary').hidden = maskCount < 1;
    el('quick-mask-summary').textContent = maskCount < 1 ? '' : maskCount.toLocaleString('ja-JP') + '件の数値を伏せてCopilotへ送り、訳案では元の数値に戻しました。';
    el('quick-promote').hidden = !toEnglish;
    el('quick-result').hidden = false;
    if (wasRevision) {
      if (artifact.revision_error) {
        el('quick-revise-status').textContent = '直せませんでした。現在の訳案は変わっていません。' + artifact.revision_error;
      } else {
        el('quick-revise-status').textContent = '指示に合わせて訳案を更新しました。AIによる未確認の訳案です。';
        el('quick-revise-instruction').value = '';
        el('quick-revise-form').hidden = true;
        el('quick-revise-open').setAttribute('aria-expanded', 'false');
      }
    } else {
      el('quick-revise-status').textContent = '';
    }
    update();
    YakuCommon.focus(el('quick-result-title'));
  }

  function poll(jobId, failureCount) {
    window.clearTimeout(pollTimer);
    failureCount = Number(failureCount || 0);
    YakuCommon.json('/api/quick/jobs/' + encodeURIComponent(jobId)).then(function (data) {
      if (data.artifact && (data.mode === 'done' || data.mode === 'completed_with_warnings')) { finish(data); return; }
      if (['error', 'failed', 'cancelled'].indexOf(data.mode) >= 0) {
        var failedRevision = revisionInFlight; revisionInFlight = false; activeSourceSnapshot = ''; busy = false; update();
        if (failedRevision) el('quick-revise-status').textContent = '直せませんでした。現在の訳案は変わっていません。';
        showError(data.error || data.detail || '翻訳を完了できませんでした。'); return;
      }
      renderJob(data.label || data.phase || '訳案を作成中', data.progress || 0);
      pollTimer = window.setTimeout(function () { poll(jobId, 0); }, 900);
    }).catch(function () {
      var nextFailure = failureCount + 1;
      renderJob(nextFailure < 3 ? '処理状況をもう一度確認しています' : '接続の回復を待っています。文章は再送していません', 0);
      pollTimer = window.setTimeout(function () { poll(jobId, nextFailure); }, Math.min(5000, 700 * Math.pow(2, Math.min(nextFailure, 3))));
    });
  }

  function showError(message) {
    el('quick-job').innerHTML = '<div class="alert alert-error">' + YakuCommon.escape(message || '処理を完了できませんでした。') + '</div>';
    YakuCommon.focus(el('quick-job'));
  }

  function submit(event) {
    event.preventDefault();
    var text = el('quick-input').value.trim();
    if (!text || busy || !ready) return;
    activeSourceSnapshot = text;
    busy = true; artifact = null; el('quick-result').hidden = true; update(); renderJob('翻訳ジョブを開始中', 0);
    YakuCommon.post('/api/quick/jobs', { input_text: text, direction_intent: explicitDirection || 'auto' }).then(function (data) {
      if (!data.job_id) throw new Error('翻訳ジョブを開始できませんでした。');
      poll(data.job_id);
    }).catch(function (error) {
      activeSourceSnapshot = ''; busy = false; update();
      if (error.status === 409 && error.data && error.data.code === 'DIRECTION_CONFIRMATION_REQUIRED') { showChoice(error.data.error); return; }
      showError(error.message);
    });
  }

  function submitPendingWhenReady() {
    if (window.__yakuPendingQuickSubmit !== true || !ready || busy || !el('quick-input').value.trim()) return;
    window.__yakuPendingQuickSubmit = false;
    el('quick-form').requestSubmit();
  }

  function start() {
    YakuCommon.start();
    YakuCommon.onReady(function (value) { ready = value; update(); submitPendingWhenReady(); });
    window.addEventListener('yaku-pending-quick-submit', submitPendingWhenReady);
    el('quick-input').addEventListener('input', function () { explicitDirection = ''; artifact = null; el('quick-result').hidden = true; update(); });
    el('quick-form').addEventListener('submit', submit);
    el('quick-direction-change').addEventListener('click', function () { showChoice('翻訳先を変更できます。'); });
    document.querySelectorAll('[data-quick-direction]').forEach(function (button) { button.addEventListener('click', function () { explicitDirection = button.getAttribute('data-quick-direction'); el('quick-direction-choice').hidden = true; update(); YakuCommon.focus(el('quick-submit')); }); });
    el('quick-copy').addEventListener('click', function () { if (!artifact) return; var fallback = el('quick-copy-fallback'); fallback.hidden = true; YakuCommon.copyText(artifact.translation, fallback, el('quick-copy-status')); });
    el('quick-revise-open').addEventListener('click', function () {
      if (!artifact || busy) return;
      var form = el('quick-revise-form'); form.hidden = false;
      el('quick-revise-open').setAttribute('aria-expanded', 'true');
      el('quick-revise-status').textContent = '';
      YakuCommon.focus(el('quick-revise-instruction'));
    });
    el('quick-revise-cancel').addEventListener('click', function () {
      if (busy) return;
      el('quick-revise-instruction').value = '';
      el('quick-revise-form').hidden = true;
      el('quick-revise-open').setAttribute('aria-expanded', 'false');
      YakuCommon.focus(el('quick-revise-open'));
    });
    el('quick-revise-form').addEventListener('submit', function (event) {
      event.preventDefault();
      var instruction = el('quick-revise-instruction').value.trim();
      if (!artifact || busy || !instruction) { if (!instruction) YakuCommon.focus(el('quick-revise-instruction')); return; }
      activeSourceSnapshot = el('quick-input').value.trim();
      busy = true; revisionInFlight = true; update();
      el('quick-revise-status').textContent = '指示に合わせて訳案を直しています。現在の訳案は、完了するまで変わりません。完了まで操作は不要です。';
      renderJob('表現を直しています', 0);
      var requestId = window.crypto.randomUUID().replace(/-/g, '');
      YakuCommon.post('/api/quick/artifacts/' + encodeURIComponent(artifact.artifact_id) + '/revisions', {
        expected_version: artifact.version,
        instruction: instruction,
        request_id: requestId
      }).then(function (data) {
        if (!data.job_id) throw new Error('修正を開始できませんでした。');
        poll(data.job_id);
      }).catch(function (error) {
        activeSourceSnapshot = ''; revisionInFlight = false; busy = false; update();
        el('quick-revise-status').textContent = '直せませんでした。現在の訳案は変わっていません。';
        showError(error.message);
      });
    });
    el('quick-promote').addEventListener('click', function () {
      if (!artifact || !artifact.artifact_id) return;
      var button = el('quick-promote'); button.disabled = true; button.textContent = '資料翻訳へ移しています…';
      YakuCommon.post('/api/cat/promote', { artifact_id: artifact.artifact_id }).then(function (data) {
        if (!data.project_id) throw new Error('資料翻訳へ移せませんでした。');
        window.location.assign('/cat?project=' + encodeURIComponent(data.project_id));
      }).catch(function (error) { button.disabled = false; button.textContent = '資料翻訳で1文ずつ確認する'; showError(error.message); });
    });
    el('quick-input').addEventListener('keydown', function (event) { if (!event.isComposing && (event.ctrlKey || event.metaKey) && event.key === 'Enter') { event.preventDefault(); el('quick-form').requestSubmit(); } });
    update(); el('quick-input').focus();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
