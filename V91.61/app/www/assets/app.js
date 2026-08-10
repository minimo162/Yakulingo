(function () {
  'use strict';

  var sessionToken = '';
  var fileMaxBytes = 50 * 1024 * 1024;
  var yakuReady = false;
  var yakuTranslating = false;
  var yakuPollTimer = null;
  var yakuJobTimer = null;
  var yakuActiveJobId = null;
  var yakuRestoredJobId = null;
  var yakuUploadedFile = null;
  var yakuSheetSelection = null;
  var yakuFileDirectionTouched = false;
  var yakuDetailsOpen = {};
  var yakuActiveTab = 'text';
  var yakuActiveJobKind = 'text';
  var yakuCopilotCalls3h = 0;
  var yakuCatUsage = null;
  var yakuCatUsageRequest = 0;
  var yakuCatFocusFirstAfterRender = false;
  // CAT の結果はグリッドへ出すので、共有の結果欄は常に空のままでよい。
  var yakuResultByTab = { text: '', file: '', cat: '' };
  var yakuLastManualScrollAt = 0;

  function yakuMarkManualScroll() { yakuLastManualScrollAt = Date.now(); }
  window.addEventListener('wheel', yakuMarkManualScroll, { passive: true });
  window.addEventListener('touchmove', yakuMarkManualScroll, { passive: true });
  window.addEventListener('pointerdown', function (event) {
    if (event && event.pointerType) yakuMarkManualScroll();
  }, { passive: true });
  window.addEventListener('keydown', function (event) {
    if (event && ['PageDown', 'PageUp', 'Home', 'End', 'ArrowDown', 'ArrowUp', ' '].indexOf(event.key) >= 0) yakuMarkManualScroll();
  });

  function yakuEmptyResultHtml() {
    return '<div class="empty-state">翻訳結果はここに表示されます</div>';
  }

  function yakuScrollCompletionIntoView(container) {
    if (!container || Date.now() - yakuLastManualScrollAt < 2000) return;
    var target = container.querySelector('.alert-error, .alert-warning, [data-yaku-state="done"], .result-stack') || container.firstElementChild || container;
    var rect = target.getBoundingClientRect();
    if (rect.bottom < 0) return;
    if (rect.top >= 0 && rect.bottom <= window.innerHeight) return;
    var reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    window.requestAnimationFrame(function () {
      target.scrollIntoView({ behavior: reduced ? 'auto' : 'smooth', block: 'start' });
    });
  }

  function yakuMeta(name) {
    var element = document.querySelector('meta[name="' + name + '"]');
    return element ? String(element.content || '') : '';
  }

  sessionToken = yakuMeta('yaku-session');
  fileMaxBytes = Number(yakuMeta('yaku-file-max-bytes')) || fileMaxBytes;
  document.addEventListener('htmx:configRequest', function (event) {
    if (event.detail && event.detail.headers) event.detail.headers['X-Yaku-Session'] = sessionToken;
  });

  function yakuFetch(url, options) {
    var init = options ? Object.assign({}, options) : {};
    var headers = new Headers(init.headers || {});
    headers.set('X-Yaku-Session', sessionToken);
    init.headers = headers;
    init.cache = 'no-store';
    init.credentials = 'same-origin';
    return window.fetch(url, init);
  }

  function yakuJsonPost(url, data) {
    return yakuFetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(data || {})
    });
  }

  function yakuResponseJson(response) {
    return response.json().catch(function () { return {}; }).then(function (data) {
      data = data || {};
      if (!response.ok) {
        var error = new Error(yakuUserFacingError(data.error || data.detail || ('HTTP ' + response.status)));
        error.status = response.status;
        error.code = data.error_code || '';
        throw error;
      }
      return data;
    });
  }

  function yakuResponseText(response) {
    return response.text().then(function (text) {
      if (!response.ok) throw new Error(yakuUserFacingError(text || ('HTTP ' + response.status)));
      return text;
    });
  }

  function yakuPlainErrorText(message) {
    var text = String(message || '');
    // 一部のAPIは警告HTMLを返す。Error.messageへそのまま入れてからescapeすると、
    // 利用者には <div class=...> が文字として見えるため、表示用には本文だけを取る。
    if (/<[a-z][\s\S]*>/i.test(text) && typeof document !== 'undefined' && document.createElement) {
      var box = document.createElement('div');
      box.innerHTML = text;
      var plain = (box.textContent || box.innerText || '').trim();
      if (plain) text = plain;
    }
    return text;
  }

  function yakuUserFacingError(message) {
    var raw = String(message || '');
    if (/(?:EXTERNAL_SEND_|PROTECTION_RECEIPT_|PROTECTED_PROMPT_|CAT_PROTECTED_|SHORTEN_UNMASKED_CURRENT)/.test(raw)) {
      return '安全に送る準備を完了できなかったため、送信を中止しました。原文は送信されていません。再起動後も続く場合は管理者へ連絡してください。（YK-PROTECT-01）';
    }
    return yakuPlainErrorText(raw);
  }

  function yakuScrollBehavior() {
    return window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth';
  }

  function yakuFormatBytes(bytes) {
    var n = Number(bytes) || 0;
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
    return (n / (1024 * 1024)).toFixed(1) + ' MB';
  }

  function yakuEscape(text) {
    return String(text || '').replace(/[&<>"']/g, function (ch) {
      return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch];
    });
  }

  function yakuDecodeB64(value) {
    if (!value) return '';
    var binary = atob(value);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
    return window.TextDecoder ? new TextDecoder('utf-8').decode(bytes) : decodeURIComponent(escape(binary));
  }

  function yakuStatusClass(value) {
    return ['ok', 'warn', 'idle'].indexOf(value) >= 0 ? value : 'idle';
  }

  function yakuClampProgress(value) {
    return Math.max(0, Math.min(100, Number(value) || 0));
  }

  function yakuSetStatus(label, klass) {
    var status = document.getElementById('copilot-status');
    if (!status) return;
    status.innerHTML = '<span class="status-dot ' + yakuStatusClass(klass) + '"></span><span>' + yakuEscape(label || 'Preparing') + '</span>';
  }

  function yakuHasFileSource() {
    var fileInput = document.getElementById('file-input');
    var pathInput = document.getElementById('file-path');
    return !!((fileInput && fileInput.files && fileInput.files.length) || (pathInput && pathInput.value.trim()));
  }

  function yakuUpdateFileButton() {
    var translate = document.getElementById('file-translate-button');
    var info = document.getElementById('file-info-button');
    var hasSource = yakuHasFileSource();
    var noSheetsSelected = yakuHasExplicitEmptySheetSelection();
    var canStart = yakuReady && !yakuTranslating && hasSource && !noSheetsSelected;
    if (translate) {
      translate.disabled = !canStart;
      translate.setAttribute('aria-disabled', canStart ? 'false' : 'true');
      translate.textContent = yakuTranslating ? '翻訳中' : (yakuReady ? '翻訳' : '準備中');
    }
    if (info) info.disabled = !hasSource || yakuTranslating;
    yakuUpdateSheetSelectionWarning(noSheetsSelected);
  }

  function yakuHasExplicitEmptySheetSelection() {
    var input = document.getElementById('file-sheets');
    return Array.isArray(yakuSheetSelection) && yakuSheetSelection.length === 0 && (!input || !input.value.trim());
  }

  function yakuUpdateSheetSelectionWarning(show) {
    var warning = document.getElementById('sheet-selection-warning');
    if (warning) warning.hidden = !show;
  }

  function yakuSetButtonEnabled(enabled) {
    var button = document.getElementById('translate-button');
    if (button) {
      var active = !!enabled && !yakuTranslating;
      button.disabled = !active;
      button.setAttribute('aria-disabled', active ? 'false' : 'true');
      button.setAttribute('data-ready', active ? '1' : '0');
      button.textContent = yakuTranslating ? '訳案を作成中' : (enabled ? '訳案を作る' : '準備中');
    }
    // CAT の Copilot を使うボタンも同じ扱いにする。無効化していなかったので、
    // CAT から始めた人が押しても画面が完全に無反応になっていた。
    // 主役にしたい画面の入口で、押しても何も起きないのは致命的である。
    var catActive = !!enabled && !yakuTranslating;
    [['cat-run-button', '残りの訳案を作る'], ['cat-translate-button', '残りの訳案を作る'], ['cat-corpus-button', '参考文例を表示']].forEach(function (pair) {
      var b = document.getElementById(pair[0]);
      if (!b) return;
      b.disabled = !catActive;
      b.setAttribute('aria-disabled', catActive ? 'false' : 'true');
      b.textContent = yakuTranslating ? '実行中' : (enabled ? pair[1] : '準備中');
    });
    document.querySelectorAll('form[data-yaku-revise] button, [data-yaku-shorten]').forEach(function (b) {
      b.disabled = !enabled || yakuTranslating;
      b.title = '';
    });
    var catOpen = document.getElementById('cat-open-button');
    if (catOpen && yakuCatSourceMode() === 'align') {
      catOpen.disabled = !enabled || yakuTranslating;
      catOpen.title = '';
    } else if (catOpen) {
      catOpen.disabled = yakuTranslating;
      catOpen.title = '';
    }
    var catDelete = document.getElementById('cat-delete-button');
    if (catDelete) {
      catDelete.disabled = yakuTranslating;
      catDelete.title = yakuTranslating ? '実行中の処理が終わってから削除できます。' : '';
    }
    // CATジョブ中はproject全体を固定する。別作業への切替や行編集を許すと、
    // 開始時revisionの結果と現在画面が交差し、古い訳の混入や競合になる。
    document.querySelectorAll('#panel-cat [data-yaku-cat-input]').forEach(function (input) {
      input.readOnly = !!yakuTranslating;
      input.setAttribute('aria-readonly', yakuTranslating ? 'true' : 'false');
    });
    document.querySelectorAll('#panel-cat [data-yaku-cat-ok], #panel-cat [data-yaku-cat-merge], #panel-cat [data-yaku-cat-split], #panel-cat [data-yaku-cat-toglossary], #panel-cat [data-yaku-cat-insert], #cat-switch-project, #cat-export-button, #cat-delete-button, [data-yaku-main-entry], [data-yaku-open-workspace]').forEach(function (control) {
      if (yakuTranslating) {
        if (!control.disabled) control.setAttribute('data-yaku-job-disabled', '1');
        control.disabled = true;
      } else if (control.hasAttribute('data-yaku-job-disabled')) {
        control.removeAttribute('data-yaku-job-disabled');
        if (control.id === 'cat-export-button') control.disabled = !!(yakuCatData && yakuCatData.export_blocked) || yakuCatDirtyInputs().length > 0;
        else control.disabled = false;
      }
    });
    yakuUpdateFileButton();
  }

  function yakuSetStartupMessage(data) {
    var gate = document.getElementById('startup-gate');
    if (!gate) return;
    if (data && data.ready) {
      gate.textContent = '';
      gate.hidden = true;
      return;
    }
    gate.hidden = false;
    if (data && data.mode === 'login') gate.textContent = 'Copilotにログインしてください。ログイン後、自動で翻訳ボタンが有効になります。';
    else if (data && (data.mode === 'error' || data.mode === 'timeout')) gate.textContent = (data.label || 'エラー') + (data.detail ? '：' + data.detail : '');
    else gate.textContent = 'Copilotを準備しています';
  }

  function yakuApplyReadyState(data) {
    yakuReady = !!(data && data.canTranslate);
    yakuCopilotCalls3h = data && typeof data.copilotCalls3h === 'number' ? data.copilotCalls3h : 0;
    if (yakuCatUsage) yakuCatUsage.calls_last_3h = yakuCopilotCalls3h;
    if (data) yakuSetStatus(data.label, data.class);
    yakuSetButtonEnabled(yakuReady);
    yakuSetStartupMessage(data);
    yakuCatUpdateUsage();
  }

  function yakuPollReadyState() {
    window.clearTimeout(yakuPollTimer);
    yakuFetch('/api/ready-state').then(yakuResponseJson).then(function (data) {
      yakuApplyReadyState(data);
      yakuPollTimer = window.setTimeout(yakuPollReadyState, data.canTranslate ? 5000 : 1500);
    }).catch(function () {
      yakuSetStatus('Preparing', 'warn');
      yakuSetButtonEnabled(false);
      yakuPollTimer = window.setTimeout(yakuPollReadyState, 2500);
    });
  }

  // Keep these character sets identical to the PowerShell constants in src/PromptBuilder.ps1.
  var YAKU_ZH_ONLY = '们说这电买卖气汉车马鸟龙国际经济发东乐业专应见观议贝页风飞习书记语读谈请谁边达迟运过还进邮针钱银错门问间闻阳阴际陈难预领题风飘饭馆驶验鱼给绩线组织续维总编罗聚台么为兴举义乌产亿仅从优会伤估体余你侧价俭修倾储儿元党军写农凉减务动劳势区医华单卖南历厂压厅参双变叙叠只号叹后吓吕吗听启呜咏员响哑';
  var YAKU_JA_ONLY = '経済険応図売変対発拡広働込峠畑辻榊塩駅円団囲桜権沢浜渋瀬焼県窓縁労効単継絵転軽験鉄銭関顔悪帰実読満児仏圧巻歩黒麺涙戦絶縦緑総聴脳臓芸薬蔵訳証誉譲豊軸辺逓遅郷酔釈鋭録雑霊価併侮倹偽厳寿嘱囑噴壊壌壱奨姉娯嬢学宝実寛専岳峡巌帯帰廃弐弾従徳恵悩悪惨愉慎憎懐戸戻抜択拝拠挙掲揺摂撃斉断旧昼晩暁暑暦朗楽横欧歓歳残殴毎氷汚決渉済渇温湿滝滞漢潜瀬灯炉点為犬状独猟獣産畳癒発盗県真研砕碁秘称稲穀穂穏突窃絹継続総緒縄縦繊缶聖粛脇脱脹与';

  function yakuAnalyzeDirection(value) {
    if (!value.trim()) return { dir: null, conf: 'high' };
    var kana = (value.match(/[ぁ-んァ-ヶｦ-ﾟ]/g) || []).length;
    var han = (value.match(/[一-龯㐀-䶵々〆]/g) || []).length;
    var latin = (value.match(/[A-Za-z]/g) || []).length;
    var meaningful = kana + han + latin;
    if (!meaningful) return { dir: 'to_jp', conf: 'low' };
    if (kana > 0) {
      var ratio = (kana + han) / meaningful;
      if (ratio >= 0.30) return { dir: 'to_en', conf: 'high' };
      if (ratio <= 0.10) return { dir: 'to_jp', conf: 'high' };
      return { dir: 'to_jp', conf: 'low' };
    }
    if (han > 0) {
      var hasZh = false, hasJa = false;
      for (var i = 0; i < value.length; i++) {
        if (YAKU_ZH_ONLY.indexOf(value[i]) >= 0) hasZh = true;
        else if (YAKU_JA_ONLY.indexOf(value[i]) >= 0) hasJa = true;
        if (hasZh && hasJa) break;
      }
      if (hasZh && !hasJa) return { dir: 'to_jp', conf: 'high' };
      var hanRatio = han / meaningful;
      if (hasJa && hanRatio >= 0.30) return { dir: 'to_en', conf: 'high' };
      if (hanRatio >= 0.30) return { dir: 'to_en', conf: 'low' };
    }
    return { dir: 'to_jp', conf: 'high' };
  }

  function yakuUpdateInputMeta() {
    var input = document.getElementById('input-text');
    var counter = document.getElementById('char-count');
    var direction = document.getElementById('direction-indicator');
    var warning = document.getElementById('direction-warning');
    var value = input ? input.value : '';
    if (counter) counter.textContent = Array.from(value).length.toLocaleString('ja-JP') + '字';
    var checked = document.querySelector('input[name="text_direction"]:checked');
    var selected = checked ? checked.value : 'auto';
    var analysis = yakuAnalyzeDirection(value);
    if (direction) {
      if (!value.trim()) direction.textContent = '-';
      else if (selected !== 'auto') direction.textContent = (selected === 'to_en' ? '日本語から英語' : '英語などから日本語') + '（指定済み）';
      else direction.textContent = analysis.dir === 'to_en' ? '日本語から英語' : '英語などから日本語';
    }
    if (warning) warning.hidden = !(value.trim() && selected === 'auto' && analysis.conf === 'low');
  }

  function yakuUpdateFileMeta(html) {
    var meta = document.getElementById('file-meta');
    if (meta) meta.innerHTML = html || 'ファイルを選択するか、ローカルパスを入力してください。';
    yakuUpdateFileButton();
  }

  function yakuResetFileInfoMessage() {
    var fileInput = document.getElementById('file-input');
    var pathInput = document.getElementById('file-path');
    var name = document.getElementById('file-name');
    var row = document.getElementById('file-selected-row');
    var selectedName = row ? row.querySelector('.file-selected-name') : null;
    var selectedSize = row ? row.querySelector('.file-selected-size') : null;
    var hasFile = !!(fileInput && fileInput.files && fileInput.files.length);
    if (name) name.textContent = hasFile ? '選択済み' : 'ローカルパス指定も利用できます';
    if (row) row.hidden = !hasFile;
    if (hasFile && selectedName) selectedName.textContent = fileInput.files[0].name;
    if (hasFile && selectedSize) selectedSize.textContent = yakuFormatBytes(fileInput.files[0].size);
    if (pathInput && pathInput.value.trim()) yakuUpdateFileMeta('パス指定: ' + yakuEscape(pathInput.value.trim()));
    else if (hasFile) yakuUpdateFileMeta('選択中: ' + yakuEscape(fileInput.files[0].name));
    else yakuUpdateFileMeta('');
  }

  function yakuJobLoadingHtml(jobId, progress, detail, phase) {
    var pct = yakuClampProgress(progress);
    var attr = jobId ? ' data-yaku-job-id="' + yakuEscape(jobId) + '"' : '';
    var cancel = jobId ? '<button type="button" class="secondary-button compact cancel-button" data-yaku-job-id="' + yakuEscape(jobId) + '">キャンセル</button>' : '';
    return '<div class="result-loading job-loading"' + attr + '><div class="job-loading-inner">' +
      '<div class="job-topline"><div class="job-phase" role="status" aria-live="polite">' + yakuEscape(phase || '翻訳準備中') + '</div><div class="job-percent">' + Math.round(pct) + '%</div></div>' +
      '<div class="job-progress-line" role="progressbar" aria-label="翻訳進捗" aria-valuemin="0" aria-valuemax="100" aria-valuenow="' + Math.round(pct) + '"><span class="job-progress-bar" style="width:' + pct + '%"></span></div>' +
      '<div class="job-bottomline"><div class="job-meta">' + yakuEscape(detail || '進捗を取得しています') + '</div>' + cancel + '</div></div></div>';
  }

  function yakuGetResultTarget() {
    return document.getElementById('job-result');
  }

  function yakuRenderJobLoading(jobId, progress, detail, phase) {
    var result = yakuGetResultTarget();
    if (!result) return;
    result.setAttribute('aria-busy', 'true');
    result.innerHTML = yakuJobLoadingHtml(jobId, progress, detail, phase);
  }

  function yakuScrollJobResultIntoView() {
    var result = yakuGetResultTarget();
    if (!result) return;
    var reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    result.scrollIntoView({ behavior: reduced ? 'auto' : 'smooth', block: 'nearest' });
  }

  function yakuUpdateJobCard(data) {
    var result = yakuGetResultTarget();
    var pct = yakuClampProgress(data && data.progress);
    var line = result && result.querySelector('.job-progress-line');
    var bar = result && result.querySelector('.job-progress-bar');
    var phase = result && result.querySelector('.job-phase');
    var meta = result && result.querySelector('.job-meta');
    var percent = result && result.querySelector('.job-percent');
    if (line) line.setAttribute('aria-valuenow', String(Math.round(pct)));
    if (bar) bar.style.width = pct + '%';
    if (phase) phase.textContent = data.label || data.phase || '翻訳中';
    if (percent) percent.textContent = Math.round(pct) + '%';
    if (meta && data.detail) meta.textContent = data.detail;
  }

  function yakuTerminalMode(mode) {
    return ['done', 'completed_with_warnings', 'error', 'failed', 'interrupted', 'cancelled'].indexOf(mode) >= 0;
  }

  function yakuFinishJob(data) {
    window.clearTimeout(yakuJobTimer);
    // CAT は結果を共有の結果欄へ出さない。訳文はグリッドへ取り込む。
    if (yakuActiveJobKind === 'cat') {
      var catJobId = yakuActiveJobId;
      var catJobProjectId = yakuCatJobProjectId;
      var catJobProjectRevision = yakuCatJobProjectRevision;
      yakuCatJobProjectId = '';
      yakuCatJobProjectRevision = -1;
      yakuActiveJobId = null;
      var catTarget = yakuGetResultTarget();
      if (catTarget) { catTarget.removeAttribute('aria-busy'); catTarget.innerHTML = '<div class="empty-state">実行中ジョブと翻訳結果はここに表示されます</div>'; }
      // 突き合わせは訳文ではなく対応を返す。組み立てが違うので分ける。
      var applyPromise;
      if (yakuCatDirtyInputs().length || Object.keys(yakuCatSavePromises).length) {
        yakuCatSetStatus('未保存の編集があるため、翻訳結果の取り込みを停止しました。編集内容を保存してから、もう一度「残りの訳案を作る」を実行してください。');
        yakuTranslating = false;
        yakuSetButtonEnabled(yakuReady);
        return;
      }
      if (yakuCatAligning) { yakuCatAligning = false; applyPromise = yakuCatAlignApply(catJobId); }
      else { applyPromise = yakuCatApply(catJobId, catJobProjectId, catJobProjectRevision); }
      Promise.resolve(applyPromise).then(function () {
        yakuTranslating = false;
        yakuSetButtonEnabled(yakuReady);
        yakuPollReadyState();
      }, function () {
        yakuTranslating = false;
        yakuSetButtonEnabled(yakuReady);
        yakuPollReadyState();
      });
      return;
    }
    var result = yakuGetResultTarget();
    var completedKind = 'text';
    var completedHtml = data && data.html ? data.html : '<div class="alert alert-warning">翻訳結果を取得できませんでした。</div>';
    yakuResultByTab[completedKind] = completedHtml;
    yakuTranslating = false;
    yakuActiveJobId = null;
    yakuActivateTab(completedKind);
    if (result) {
      result.removeAttribute('aria-busy');
      result.innerHTML = completedHtml;
      // 前に選んだ書き方を主へ持ってくる。毎回押し直さなくて済むように。
      yakuNotifyResultRendered();
      window.setTimeout(function () { yakuScrollCompletionIntoView(result); }, 0);
    }
    yakuSetButtonEnabled(yakuReady);
    yakuPollReadyState();
  }

  function yakuPollJobStatus() {
    if (!yakuActiveJobId) return;
    var jobId = yakuActiveJobId;
    yakuFetch('/api/jobs/' + encodeURIComponent(jobId)).then(yakuResponseJson).then(function (data) {
      yakuUpdateJobCard(data);
      if (yakuTerminalMode(data.mode)) {
        yakuFinishJob(data);
        return;
      }
      yakuJobTimer = window.setTimeout(yakuPollJobStatus, 1000);
    }).catch(function (error) {
      if (error && error.status === 404) {
        try { sessionStorage.removeItem('yaku-job-id'); sessionStorage.removeItem('yaku-job-kind'); } catch (ignore) {}
        yakuActiveJobId = null;
        yakuTranslating = false;
        var expired = yakuGetResultTarget();
        if (expired) {
          var expiredHtml = '<div class="alert alert-warning">ジョブ情報の保持期間が終了しました。出力フォルダーを確認してください。</div>';
          expired.innerHTML = expiredHtml;
          yakuResultByTab[yakuActiveJobKind] = expiredHtml;
          window.setTimeout(function () { yakuScrollCompletionIntoView(expired); }, 0);
        }
        yakuSetButtonEnabled(yakuReady);
        return;
      }
      yakuRenderJobLoading(jobId, 0, error.message || 'ジョブ状態を再取得します', '接続確認中');
      yakuJobTimer = window.setTimeout(yakuPollJobStatus, 1500);
    });
  }

  function yakuStartJobPolling(jobId, kind) {
    if (!jobId) return;
    yakuActiveJobId = jobId;
    // CAT も残す。ここで text へ丸めると、完了時にグリッドへ取り込む枝が通らない。
    var normalizedKind = kind === 'cat' ? 'cat' : 'text';
    yakuActiveJobKind = normalizedKind;
    yakuTranslating = true;
    try {
      sessionStorage.setItem('yaku-job-id', jobId);
      sessionStorage.setItem('yaku-job-kind', normalizedKind);
    } catch (ignore) {}
    yakuSetButtonEnabled(false);
    window.clearTimeout(yakuJobTimer);
    yakuPollJobStatus();
  }

  function yakuRestoreTabJob() {
    var jobId = '';
    var kind = 'text';
    try { jobId = sessionStorage.getItem('yaku-job-id') || ''; kind = sessionStorage.getItem('yaku-job-kind') || 'text'; } catch (ignore) {}
    if (!jobId || yakuRestoredJobId === jobId) return;
    // CAT のジョブは復元しない。画面を読み直すと取り込んだ一覧が消えており、
    // 訳文の戻し先が無い。中途半端に復元すると、消えた一覧へ入れようとして失敗する。
    if (kind === 'cat') {
      try { sessionStorage.removeItem('yaku-job-id'); sessionStorage.removeItem('yaku-job-kind'); } catch (ignore) {}
      return;
    }
    yakuRestoredJobId = jobId;
    yakuActivateTab('text');
    yakuRenderJobLoading(jobId, 0, 'このタブのジョブを復元しています', '結果確認中');
    yakuStartJobPolling(jobId, kind);
  }

  function yakuNotifyResultRendered() {
    try { document.dispatchEvent(new CustomEvent('yaku:result-rendered')); } catch (e) {}
  }
  function yakuStartFromHtml(html) {
    var result = yakuGetResultTarget();
    if (result) result.innerHTML = html || '<div class="alert alert-warning">ジョブ開始結果を取得できませんでした。</div>';
    var job = result && result.querySelector('[data-yaku-job-id]');
    if (!job) throw new Error('ジョブIDを取得できませんでした。');
    result.setAttribute('aria-busy', 'true');
    yakuStartJobPolling(job.getAttribute('data-yaku-job-id'), job.getAttribute('data-yaku-kind') || 'text');
  }

  function yakuShowStartError(error, fallback) {
    var result = yakuGetResultTarget();
    if (result) {
      result.removeAttribute('aria-busy');
      var errorHtml = '<div class="alert alert-error">' + yakuEscape(yakuUserFacingError(error && error.message ? error.message : fallback)) + '</div>';
      result.innerHTML = errorHtml;
      yakuResultByTab[yakuActiveJobKind] = errorHtml;
      window.setTimeout(function () { yakuScrollCompletionIntoView(result); }, 0);
    }
    yakuTranslating = false;
    yakuActiveJobId = null;
    yakuSetButtonEnabled(yakuReady);
    yakuPollReadyState();
  }

  function yakuSubmitText(event) {
    event.preventDefault();
    var input = document.getElementById('input-text');
    var text = input ? input.value : '';
    if (!text.trim()) return;
    if (!yakuReady || yakuTranslating) { yakuPollReadyState(); return; }
    yakuTranslating = true;
    yakuActiveJobKind = 'text';
    yakuSetButtonEnabled(false);
    yakuRenderJobLoading('', 0, '翻訳ジョブを開始中', '準備中');
    yakuScrollJobResultIntoView();
    var checked = document.querySelector('input[name="text_direction"]:checked');
    yakuJsonPost('/api/translate-text', { input_text: text, direction: checked ? checked.value : 'auto' }).then(yakuResponseText).then(yakuStartFromHtml).catch(function (error) {
      yakuShowStartError(error, 'テキスト翻訳を開始できませんでした。');
    });
  }

  function yakuDecodeBase64Utf8(value) {
    // 原文と現訳は base64 で札に載っている。改行や引用符を属性へ
    // そのまま置けないため。
    if (!value) return '';
    var binary = window.atob(value);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return new TextDecoder('utf-8').decode(bytes);
  }

  function yakuSubmitRevision(form) {
    // できあがった訳文へ指示を1つ当てて直す。翻訳と同じジョブの仕組みに
    // 乗せるのは、Copilot への往復が1度に1つでなければならないため。
    var input = form.querySelector('.revise-input');
    var instruction = input ? input.value : '';
    if (!instruction.trim()) { if (input) input.focus(); return; }
    if (!yakuReady || yakuTranslating) { yakuPollReadyState(); return; }
    // 送るのはマスク後の訳文。画面に出ている訳文は実値へ戻した後のもので、
    // そのまま送ると伏せた数値が外へ出る。
    var payload = {
      source_text: yakuDecodeBase64Utf8(form.getAttribute('data-yaku-source')),
      current_text: yakuDecodeBase64Utf8(form.getAttribute('data-yaku-current')),
      instruction: instruction,
      style: form.getAttribute('data-yaku-style') || 'full',
      direction: form.getAttribute('data-yaku-direction') || 'to_en'
    };
    yakuTranslating = true;
    yakuActiveJobKind = 'text';
    yakuSetButtonEnabled(false);
    yakuRenderJobLoading('', 0, '修正を依頼中', '準備中');
    yakuScrollJobResultIntoView();
    yakuJsonPost('/api/revise-text', payload).then(yakuResponseText).then(yakuStartFromHtml).catch(function (error) {
      yakuShowStartError(error, '修正を依頼できませんでした。');
    });
  }

  function yakuSubmitShorten(button) {
    // 訳文を短くする。押されたときだけ Copilot を呼ぶ。
    // 毎回2本作ると、Copilot が使える文の数が半分になる（120回で止まる）。
    if (!yakuReady || yakuTranslating) { yakuPollReadyState(); return; }
    // 送るのはマスク後の訳文。画面に出ている訳文は実値へ戻した後のもので、
    // そのまま送ると伏せた数値が外へ出る。
    var payload = {
      source_text: yakuDecodeBase64Utf8(button.getAttribute('data-yaku-source-b64')),
      current_text: yakuDecodeBase64Utf8(button.getAttribute('data-yaku-current-b64'))
    };
    yakuTranslating = true;
    yakuActiveJobKind = 'text';
    yakuSetButtonEnabled(false);
    yakuRenderJobLoading('', 0, '短くしています', '準備中');
    yakuScrollJobResultIntoView();
    yakuJsonPost('/api/shorten-text', payload).then(yakuResponseText).then(yakuStartFromHtml).catch(function (error) {
      yakuShowStartError(error, '短くできませんでした。');
    });
  }

  // ---------------------------------------------------------------- CAT
  // ファイル翻訳と同じことを、押した分だけ進める。
  // 取り込む → 用語集で置換 → 残りをCopilotで訳す → 出力。
  var yakuCatProjectId = '';
  var yakuCatSavePromises = {};
  var yakuCatSaveQueue = Promise.resolve();
  var yakuCatJobProjectId = '';
  var yakuCatJobProjectRevision = -1;
  var yakuCatDeleteTarget = null;
  // 走っているジョブが「突き合わせ」かどうか。終わったあとの組み立てが
  // 訳文の取り込みとは違うので、ここで区別する。
  var yakuCatAligning = false;
  var yakuCatUploaded = null;
  var yakuCatViewRequest = 0;
  var yakuCatAlignRequest = 0;
  var yakuCatRecentProjects = [];
  var yakuCatOutputProjectId = '';
  var yakuCatOutputRevision = -1;
  var yakuCatSaveStatusTimer = null;
  var yakuCatOperationBusy = false;
  var yakuCatCommit = function () { return Promise.resolve(false); };

  function yakuCatSetSaveStatus(text, isError) {
    var el = document.getElementById('cat-save-status');
    var current = document.getElementById('cat-current-save');
    window.clearTimeout(yakuCatSaveStatusTimer);
    var persistent = text === '保存しました' ? '保存済み' : (text || '');
    if (el) {
      el.hidden = !persistent;
      el.textContent = persistent;
      el.classList.toggle('is-error', !!isError);
    }
    if (current) {
      current.textContent = persistent || '保存済み';
      current.classList.toggle('is-error', !!isError);
      current.classList.toggle('is-saving', /保存しています/.test(persistent));
    }
  }

  function yakuCatSetFocusedMode(active, data) {
    var picker = document.getElementById('cat-picker');
    var summary = document.getElementById('cat-current-summary');
    var danger = document.getElementById('cat-danger-zone');
    var workspace = document.getElementById('cat-workspace');
    if (picker) picker.hidden = !!active;
    if (summary) summary.hidden = !active;
    if (danger) danger.hidden = !active;
    if (workspace) workspace.hidden = !active;
    if (!active || !data) return;
    var title = document.getElementById('cat-current-title');
    var progress = document.getElementById('cat-current-progress');
    if (title) title.textContent = data.file_name || '翻訳作業';
    if (progress) {
      var total = Number(data.total) || 0;
      var confirmed = Number(data.confirmed) || 0;
      progress.textContent = '全 ' + total + ' 行のうち ' + confirmed + ' 行を確認済み・残り ' + Math.max(0, total - confirmed) + ' 行';
    }
  }

  function yakuCatWithOperation(button, action) {
    if (yakuCatOperationBusy) {
      yakuCatSetStatus('処理中です。終わってから次の操作をしてください。');
      return Promise.resolve(null);
    }
    yakuCatOperationBusy = true;
    if (button) button.disabled = true;
    var panel = document.getElementById('panel-cat');
    if (panel) panel.setAttribute('aria-busy', 'true');
    var result;
    try { result = Promise.resolve(action()); }
    catch (error) { result = Promise.reject(error); }
    return result.then(function (value) {
      yakuCatOperationBusy = false;
      if (button) button.disabled = false;
      if (panel) panel.removeAttribute('aria-busy');
      return value;
    }, function (error) {
      yakuCatOperationBusy = false;
      if (button) button.disabled = false;
      if (panel) panel.removeAttribute('aria-busy');
      throw error;
    });
  }

  function yakuCatClearOutputDisplay() {
    yakuCatOutputProjectId = '';
    yakuCatOutputRevision = -1;
    var row = document.getElementById('cat-output-row');
    var name = document.getElementById('cat-output-name');
    if (row) {
      row.hidden = true;
      row.removeAttribute('data-yaku-output-project');
      row.removeAttribute('data-yaku-output-revision');
    }
    if (name) name.textContent = '';
    var textPanel = document.getElementById('cat-text-output');
    var textValue = document.getElementById('cat-text-output-value');
    if (textPanel) textPanel.hidden = true;
    if (textValue) textValue.value = '';
    var draftWarning = document.getElementById('cat-draft-warning');
    if (draftWarning && !draftWarning.hidden) {
      draftWarning.textContent = '作成するファイルは確認用DRAFTです。完成版ではなく、社外配布できません。';
    }
  }

  function yakuCatMarkDirty(input) {
    if (!input || !input.hasAttribute('data-yaku-cat-input')) return;
    input.setAttribute('data-yaku-dirty', '1');
    var row = input.closest('[data-yaku-cat-row]');
    if (row) {
      row.classList.add('cat-dirty');
      row.classList.remove('cat-unsaved');
    }
    yakuCatClearOutputDisplay();
    yakuCatSetSaveStatus('変更を保存していません', false);
    var exportBtn = document.getElementById('cat-export-button');
    if (exportBtn) exportBtn.disabled = true;
  }

  function yakuCatDirtyInputs() {
    return Array.prototype.slice.call(document.querySelectorAll('[data-yaku-cat-input][data-yaku-dirty="1"]'));
  }

  function yakuCatFlushDirtyEdits() {
    function flushPass() {
      var dirty = yakuCatDirtyInputs();
      var pending = Object.keys(yakuCatSavePromises).map(function (key) { return yakuCatSavePromises[key]; });
      if (!dirty.length && !pending.length) return Promise.resolve(true);
      var chain = Promise.resolve();
      dirty.forEach(function (input) {
        chain = chain.then(function () { return yakuCatCommit(input); });
      });
      return chain.then(function () {
        return Promise.all(Object.keys(yakuCatSavePromises).map(function (key) { return yakuCatSavePromises[key]; }));
      }).then(flushPass);
    }
    if (!yakuCatDirtyInputs().length && !Object.keys(yakuCatSavePromises).length) return Promise.resolve(true);
    yakuCatSetSaveStatus('保存しています…', false);
    return flushPass().then(function () {
      yakuCatSetSaveStatus('保存しました', false);
      return true;
    }).catch(function (error) {
      yakuCatSetSaveStatus('保存できませんでした。赤い行を確認してください。', true);
      throw error;
    });
  }

  function yakuCatAfterFlush(action) {
    return yakuCatFlushDirtyEdits().then(action).catch(function () { return null; });
  }

  function yakuCatSetStatus(text) {
    var el = document.getElementById('cat-status');
    if (el) el.textContent = text;
  }

  function yakuCatOriginLabel(origin) {
    if (origin === 'glossary') return '用語集';
    if (origin === 'copilot') return 'AI訳';
    if (origin === 'manual') return '手直し';
    if (origin === 'carried_forward') return '前回の確認済み訳';
    if (origin === 'numeric_update') return '前回訳の数値更新';
    return '';
  }

  // 最後に描いた一覧。絞り込みのたびにサーバーへ問い合わせない。
  var yakuCatData = null;

  function yakuCatFilterValue() {
    var checked = document.querySelector('input[name="cat_filter"]:checked');
    return checked ? checked.value : 'all';
  }

  function yakuCatKeep(s, mode, needle) {
    // 絞り込みは2つだけ。未翻訳は未確認に含まれるので、分ける必要がない。
    // 上から潰せば、用語集で埋まった行にも必ず目が通る。
    if (mode === 'unconfirmed' && s.confirmed) return false;
    if (needle) {
      var hay = ((s.source || '') + '\n' + (s.translation || '')).toLowerCase();
      if (hay.indexOf(needle) < 0) return false;
    }
    return true;
  }

  function yakuCatEligibilityHas(data, reason) {
    return (data.eligibility_reasons || []).indexOf(reason) >= 0;
  }

  function yakuCatOutputGuidance(data) {
    var messages = [];
    var untranslated = Number(data.untranslated) || 0;
    var unconfirmed = Number(data.unconfirmed);
    if (isNaN(unconfirmed)) unconfirmed = Math.max(0, (Number(data.total) || 0) - (Number(data.confirmed) || 0));
    var failedQc = (data.segments || []).filter(function (segment) { return (segment.qc_findings || []).length > 0; }).length;
    if (untranslated > 0) messages.push('残り ' + untranslated + ' 行の訳案を作ってください。');
    if (failedQc > 0) messages.push('検査エラーのある ' + failedQc + ' 行を直し、もう一度「確認済みにする」を押してください。');
    var needsReview = Math.max(0, unconfirmed - failedQc - untranslated);
    if (needsReview > 0) messages.push('あと ' + needsReview + ' 行を確認済みにしてください。');
    if (yakuCatEligibilityHas(data, 'source-file-missing')) messages.push('取り込んだ元ファイルが見つかりません。元の場所へ戻すか、訳文一覧を利用してください。');
    if (yakuCatEligibilityHas(data, 'project-empty')) messages.push('確認する文章がありません。');
    if (!messages.length && data.export_blocked) messages.push('未確認の行または最新でない検査結果があります。');
    return messages.join(' ');
  }

  function yakuCatRender(data) {
    var previousProjectId = yakuCatProjectId;
    if (data) yakuCatData = data;
    data = yakuCatData;
    if (!data) return;
    if ((previousProjectId && previousProjectId !== (data.id || '')) || (yakuCatOutputProjectId && yakuCatOutputProjectId !== (data.id || ''))) {
      yakuCatClearOutputDisplay();
      yakuCatSetSaveStatus('', false);
    } else if (yakuCatOutputProjectId === (data.id || '') && yakuCatOutputRevision !== (Number(data.revision) || 0)) {
      yakuCatClearOutputDisplay();
    }
    yakuCatProjectId = data.id || '';
    yakuCatSetFocusedMode(!!yakuCatProjectId, data);
    yakuCatUpdateMainResume();
    var body = document.getElementById('cat-grid-body');
    if (!body) return;
    var mode = yakuCatFilterValue();
    var searchBox = document.getElementById('cat-search');
    var needle = searchBox ? searchBox.value.trim().toLowerCase() : '';
    var rows = [];
    var all = data.segments || [];
    var segments = [];
    for (var k = 0; k < all.length; k++) { if (yakuCatKeep(all[k], mode, needle)) segments.push(all[k]); }
    var countEl = document.getElementById('cat-filter-count');
    if (countEl) countEl.textContent = (segments.length === all.length) ? '' : (segments.length + ' / ' + all.length + ' 件を表示');
    for (var i = 0; i < segments.length; i++) {
      var s = segments[i];
      // 繋いだ行は「何セルを1つにまとめたか」を出す。
      // 繋ぎ方が外れていても、ここを見れば気づける。
      var loc;
      if (s.kind === 'text') loc = s.joined ? '結合' : '文';
      else if (s.kind === 'cell') loc = s.joined ? (s.cells + 'セル結合') : 'セル';
      else loc = (s.kind === 'shape') ? '図形' : (s.kind === 'chart' ? 'グラフ' : (s.kind === 'word_paragraph' ? '段落' : (s.kind === 'word_table' ? '表内' : (s.kind.indexOf('word_') === 0 ? '文書付属領域' : s.kind))));
      var origin = yakuCatOriginLabel(s.origin);
      // 繋ぎ直しの操作。自動で完璧に分けるのは無理なので、外れたら人が直す。
      var ops = '';
      var rowNumber = s.index + 1;
      var nextSegment = s.can_merge ? all[s.index + 1] : null;
      var mergeLosesTranslation = !!((s.translation || '').trim() || (nextSegment && (nextSegment.translation || '').trim()));
      var splitLosesTranslation = !!(s.translation || '').trim();
      if (s.can_merge) ops += '<button type="button" class="cat-op" data-yaku-cat-merge="' + s.index + '" data-yaku-cat-loss="' + (mergeLosesTranslation ? '1' : '0') + '" aria-label="' + rowNumber + '行目を次の行と結合" title="次の行と結合します（訳文は消えます）">↓結合</button>';
      if (s.can_split) ops += '<button type="button" class="cat-op" data-yaku-cat-split="' + s.index + '" data-yaku-cat-loss="' + (splitLosesTranslation ? '1' : '0') + '" aria-label="' + rowNumber + '行目の結合を解除" title="セル1つずつに戻します（訳文は消えます）">解除</button>';
      // 行の状態を色で示す。市販の CAT エディタは状態列を色で分けており、
      // 一覧を眺めたときに「どこが手つかずか」が一目で分かる。
      // 状態は3つ。訳が入っているかと、人が見たかは別物である。
      var state = s.status || ((s.translation || '').trim() ? 'machine_draft' : 'untranslated');
      var stateLabel = state === 'reviewed' ? '確認済み' :
        (state === 'human_edited' ? '手編集・未確認' :
        (state === 'machine_draft' ? 'AI訳・未確認' : (state === 'stale' ? '再確認必要' : '未翻訳')));
      var findingLabels = {
        'empty': '訳文が空です。',
        'invalid-or-source-fallback': '訳文として成立していないか、原文のままです。',
        'placeholder-residue': '保護用の記号が訳文に残っています。',
        'numeric-integrity': '数値または単位が原文と一致しません。',
        'numeric-value-mismatch': '原文と異なる数値、または不足している数値があります。',
        'numeric-value-extra': '原文にない数値が訳文へ追加されています。',
        'numeric-scale-mismatch': 'million / billion と億円の桁が一致しません。',
        'numeric-sign-missing': '損失・減少を示す符号が訳文に反映されていません。',
        'accounting-polarity-mismatch': '利益と損失、または増加と減少の向きが原文と一致しません。',
        'currency-mismatch': '通貨単位が原文と一致しません。',
        'proper-noun-missing': '固有名詞が訳文に反映されていません。',
        'structure-integrity': '見出しまたは箇条書きの構造が原文と一致しません。',
        'numeric-validation-error': '数値検査を完了できませんでした。',
        'proper-noun-validation-error': '固有名詞検査を完了できませんでした。',
        'structure-validation-error': '構造検査を完了できませんでした。'
      };
      var findings = (s.qc_findings || []).map(function (finding) {
        finding = finding || {};
        var code = String(finding.code || finding.Code || '').toLowerCase().replace(/_/g, '-');
        return findingLabels[code] || '確認が必要な問題があります。';
      });
      var findingId = 'cat-qc-' + s.index;
      var findingsHtml = findings.length ? '<div id="' + findingId + '" class="cat-qc-findings" role="alert">' + findings.map(function (message) { return '<div>' + yakuEscape(message) + '</div>'; }).join('') + '</div>' : '';
      var describedBy = findings.length ? ' aria-describedby="' + findingId + '" aria-invalid="true"' : ' aria-invalid="false"';
      rows.push(
        '<tr data-yaku-cat-row="' + s.index + '" data-yaku-cat-state="' + yakuEscape(state) + '"' +
        ' data-yaku-confirmed="' + (s.confirmed ? '1' : '0') + '">' +
        '<td class="cat-col-no"><span class="cat-card-label" aria-hidden="true">行番号・状態</span>' + (s.index + 1) + '<span class="cat-state cat-state-' + state + '">' + stateLabel + '</span></td>' +
        '<td class="cat-col-loc"><span class="cat-card-label" aria-hidden="true">場所</span><span class="cat-loc" title="' + yakuEscape(s.location || '') + '">' + yakuEscape(loc) + '</span>' +
        (origin ? '<span class="cat-origin cat-origin-' + yakuEscape(s.origin) + '">' + yakuEscape(origin) + '</span>' : '') +
        (ops ? '<span class="cat-ops">' + ops + '</span>' : '') + '</td>' +
        '<td class="cat-source"><span class="cat-card-label" aria-hidden="true">原文</span>' + yakuEscape(s.source) + '</td>' +
        '<td class="cat-target"><span class="cat-card-label" aria-hidden="true">訳文</span><textarea rows="3" aria-label="' + rowNumber + '行目の訳文・' + yakuEscape(stateLabel) + '"' + describedBy + ' data-yaku-cat-input="' + s.index + '" data-yaku-original="' + yakuEscape(s.translation || '') + '">' + yakuEscape(s.translation || '') + '</textarea>' +
          ((s.prior_translation || s.prior_source_text) ?
            '<details class="cat-prior-reference"><summary>前回の文章と訳を見る</summary>' +
              (s.prior_source_text ? '<div><strong>前回の日本語</strong><br>' + yakuEscape(s.prior_source_text) + '</div>' : '') +
              (s.prior_translation ? '<div><strong>前回の英語</strong><br>' + yakuEscape(s.prior_translation) + '</div>' : '') +
            '</details>' : '') +
          // キーボードだけでなくマウスでも進められるようにする。
          // 四半期に1回しか使わない人が Ctrl+Enter を覚えている前提は成り立たない。
          '<div class="cat-row-actions">' +
          (s.confirmed ? '' : '<button type="button" class="cat-op cat-op-ok" aria-label="' + rowNumber + '行目を確認済みにする" data-yaku-cat-ok="' + s.index + '">確認済みにする</button>') +
          ((s.kind === 'cell' && (s.translation || '').trim() && s.source.length <= 40) ? '<button type="button" class="cat-op" aria-label="' + rowNumber + '行目を用語集に追加" data-yaku-cat-toglossary="' + s.index + '">用語集に追加</button>' : '') +
          '</div>' +
          findingsHtml +
          (s.can_revise ? '<form class="revise-form" data-yaku-cat-revise="' + s.index + '">' +
            '<label class="revise-label" for="cat-revise-' + s.index + '">この訳をどう直すか</label>' +
            '<div class="revise-row"><input id="cat-revise-' + s.index + '" class="revise-input" type="text" autocomplete="off" placeholder="例：主語を省き、簡潔に">' +
            '<button type="submit" class="secondary-button revise-button">この指示で直す</button></div></form>' : '') +
          '</td>' +
        '</tr>'
      );
    }
    // 描き直す前に、いまの居場所を覚えておく。
    // 一覧を全部作り直すと、スクロールは先頭へ戻り、現在行の印も消える。
    // 400行の資料の200行目で結合を押すたびに自分の位置を探し直すことになり、
    // 1行ずつ見ていくリズムが毎回途切れる。
    var scroller = document.getElementById('cat-grid-wrap');
    var keepTop = scroller ? scroller.scrollTop : 0;
    // 編集中の欄そのものを覚える。現在行の印を基準にすると、印が付いていない
    // 状態（描き直した直後など）で復元できない。
    var focused = document.activeElement;
    var hadFocus = !!(focused && focused.hasAttribute && focused.hasAttribute('data-yaku-cat-input'));
    var keepIndex = hadFocus ? focused.getAttribute('data-yaku-cat-input') : null;
    var caret = hadFocus ? focused.selectionStart : null;
    if (keepIndex === null) {
      var activeRow = document.querySelector('[data-yaku-cat-row].is-active');
      if (activeRow) keepIndex = activeRow.getAttribute('data-yaku-cat-row');
    }

    body.innerHTML = rows.join('');

    if (keepIndex !== null) {
      var again = document.querySelector('[data-yaku-cat-row="' + keepIndex + '"]');
      if (again) {
        again.classList.add('is-active');
        if (hadFocus) {
          var input = again.querySelector('[data-yaku-cat-input]');
          if (input) {
            input.focus();
            try { input.setSelectionRange(caret, caret); } catch (e) {}
          }
        }
      }
    }
    if (scroller) scroller.scrollTop = keepTop;
    var wrap = document.getElementById('cat-grid-wrap');
    if (wrap) wrap.hidden = false;
    var actions = document.getElementById('cat-actions');
    if (actions) actions.hidden = false;
    var filterRow = document.getElementById('cat-filter-row');
    if (filterRow) filterRow.hidden = false;
    // 引いた文例。検索したときだけ出る。翻訳ボタンの表示も、
    // 文例を使うかどうかが分かるように変える。
    var corpusPanel = document.getElementById('cat-corpus-panel');
    var corpus = data.corpus || [];
    if (corpusPanel) {
      corpusPanel.hidden = !data.corpus_ready;
      var countEl2 = document.getElementById('cat-corpus-count');
      if (countEl2) countEl2.textContent = corpus.length;
      var listEl = document.getElementById('cat-corpus-list');
      if (listEl) {
        listEl.innerHTML = corpus.length
          ? corpus.map(function (c) {
              return '<div class="cat-corpus-item"><div class="cat-corpus-where">' + yakuEscape(c.where) + '</div><div>' + yakuEscape(c.text) + '</div></div>';
            }).join('')
          : '<div class="muted">近い文例は見つかりませんでした。</div>';
      }
    }
    var translateBtn = document.getElementById('cat-translate-button');
    if (translateBtn) {
      translateBtn.textContent = '残りの訳案を作る';
      translateBtn.disabled = !yakuReady || yakuTranslating;
      translateBtn.title = '';
    }
    var promotionReference = document.getElementById('cat-promotion-reference');
    var promotionReferenceText = document.getElementById('cat-promotion-reference-text');
    if (promotionReference) promotionReference.hidden = !(data.promotion_reference_translation || '').trim();
    if (promotionReferenceText) promotionReferenceText.value = data.promotion_reference_translation || '';
    var runButton = document.getElementById('cat-run-button');
    if (runButton) {
      runButton.disabled = !yakuReady || yakuTranslating;
      runButton.title = '';
    }
    var glossaryButton = document.getElementById('cat-glossary-button');
    var glossaryCount = document.getElementById('cat-glossary-count');
    if (glossaryButton) glossaryButton.disabled = !(Number(data.glossary_candidates) > 0);
    if (glossaryCount) glossaryCount.textContent = Number(data.glossary_candidates) > 0 ? ('（' + data.glossary_candidates + ' 行）') : '';
    var corpusButton = document.getElementById('cat-corpus-button');
    if (corpusButton) corpusButton.disabled = !yakuReady || yakuTranslating;
    document.querySelectorAll('[data-yaku-cat-revise] button').forEach(function (button) {
      button.disabled = !yakuReady || yakuTranslating;
      button.title = '';
    });
    // 貼り付けたテキストは書き戻す元が無い。出口が違うので言葉も変える。
    var exportBtn = document.getElementById('cat-export-button');
    var sourceMissing = yakuCatEligibilityHas(data, 'source-file-missing');
    var wordFileReady = data.document_format === 'docx' && !!data.word_file_output_supported && !sourceMissing;
    if (exportBtn) {
      exportBtn.textContent = (data.source === 'file')
        ? ((data.document_format === 'docx') ? (wordFileReady ? '確認用Word DRAFT（外部配布不可）を作る' : '確認済み訳文一覧をコピー') : '確認用Excel DRAFT（外部配布不可）を作る')
        : '確認済み訳文一覧をコピー';
      // 元ファイルが無ければ再抽出できない。存在する場合は出力時に
      // 原文を再対応付けし、曖昧なら書き込む前に停止する。
      exportBtn.disabled = !!data.export_blocked || yakuCatDirtyInputs().length > 0;
      exportBtn.title = data.export_blocked ? yakuCatOutputGuidance(data) : '';
    }
    var blockedNote = document.getElementById('cat-export-blocked');
    if (blockedNote) {
      blockedNote.hidden = !data.export_blocked;
      blockedNote.textContent = data.export_blocked ? yakuCatOutputGuidance(data) : '';
    }
    var outputHelp = document.getElementById('cat-output-help');
    var draftWarning = document.getElementById('cat-draft-warning');
    var draftAvailable = data.source === 'file' && !sourceMissing && (data.document_format !== 'docx' || wordFileReady);
    if (draftWarning) {
      draftWarning.hidden = !draftAvailable;
      var hasCurrentDraft = yakuCatOutputProjectId === (data.id || '') && yakuCatOutputRevision === (Number(data.revision) || 0);
      draftWarning.textContent = hasCurrentDraft
        ? '確認用DRAFTを作成しました。完成版ではありません。社外配布しないでください。'
        : '作成するファイルは確認用DRAFTです。完成版ではなく、社外配布できません。';
    }
    if (outputHelp) {
      if (data.source !== 'file') {
        outputHelp.hidden = true;
        outputHelp.textContent = '';
      } else if (data.document_format === 'docx' && !wordFileReady) {
        outputHelp.hidden = false;
        outputHelp.textContent = sourceMissing
          ? '元のWordが見つからないため、Wordファイルは作らず確認済み訳文一覧をコピーします。'
          : 'このWordには未対応の体裁があるため、Wordファイルは作らず確認済み訳文一覧をコピーします。';
      } else {
        outputHelp.hidden = false;
        outputHelp.textContent = '作成するファイルは確認作業用です。完成版・外部公表可能資料ではありません。ファイル名と文書内にDRAFTを表示します。';
      }
    }
    // 公表実績を検証する取込経路ができるまで、公開コーパス登録は出さない。
    var saveBtn = document.getElementById('cat-save-corpus-button');
    if (saveBtn) saveBtn.hidden = true;
    var deleteBtn = document.getElementById('cat-delete-button');
    if (deleteBtn) {
      deleteBtn.disabled = yakuTranslating;
      deleteBtn.title = yakuTranslating ? '実行中の処理が終わってから削除できます。' : '';
    }
    var versionNote = '';
    if (data.version_update) {
      versionNote = '・前回から引継ぎ ' + (Number(data.version_update.CarriedForward) || 0) +
        ' / 数値更新 ' + (Number(data.version_update.NumericUpdated) || 0) +
        ' / 変更・新規 ' + ((Number(data.version_update.Changed) || 0) + (Number(data.version_update.New) || 0));
    }
    var wordWarning = (data.source === 'file' && data.document_format === 'docx' && data.word_inventory && !data.word_inventory.draft_structure_eligible)
      ? '・このWordは未対応の体裁を含むため、訳文一覧で仕上げます（Wordファイルは出力しません）'
      : '';
    yakuCatSetStatus(data.review_blocked ? '確認できませんでした。赤く表示された検査結果を直してください。' : (data.file_name + ' … ' + data.total + ' 行（訳あり ' + data.translated + ' / 残り ' + data.remaining + '、結合 ' + data.joined + versionNote + '）' + wordWarning));
    yakuCatUpdateProgress(data);
    yakuCatRefreshUsage();
    if (yakuTranslating) yakuSetButtonEnabled(false);
    if (yakuCatFocusFirstAfterRender) {
      yakuCatFocusFirstAfterRender = false;
      window.setTimeout(function () {
        var reference = (data.promotion_reference_translation || '').trim() ? document.getElementById('cat-promotion-reference-text') : null;
        if (reference) {
          yakuCatSetStatus('文数が合わないため、訳案を自動配置していません。下の訳案を見ながら1文ずつ確認してください。');
          reference.focus();
          reference.scrollIntoView({ behavior: yakuScrollBehavior(), block: 'center' });
          return;
        }
        var first = document.querySelector('[data-yaku-cat-row][data-yaku-confirmed="0"] [data-yaku-cat-input]') || document.querySelector('[data-yaku-cat-input]');
        if (!first) return;
        first.focus();
        try { first.setSelectionRange(first.value.length, first.value.length); } catch (e) {}
        first.scrollIntoView({ behavior: yakuScrollBehavior(), block: 'center' });
      }, 0);
    }
  }

  function yakuCatUpdateUsage() {
    var el = document.getElementById('cat-copilot-usage');
    if (!el) return;
    if (!yakuCatData || !yakuCatData.segments || !yakuCatUsage) { el.hidden = true; return; }
    var estimated = Number(yakuCatUsage.estimated_calls) || 0;
    var recent = Number(yakuCatUsage.calls_last_3h) || 0;
    var hits = Number(yakuCatUsage.cache_hits) || 0;
    el.hidden = false;
    el.textContent = estimated > 0
      ? ('残りの翻訳でCopilotを約 ' + estimated + ' 回使います。直近3時間の使用は ' + recent + ' 回です。' + (hits ? ' 前回の結果を ' + hits + ' 件再利用します。' : '') + ' 再試行で増えることがあります。')
      : ('未翻訳または再利用できる訳だけです。直近3時間のCopilot使用は ' + recent + ' 回です。');
  }

  function yakuCatRefreshUsage() {
    if (!yakuCatProjectId) { yakuCatUsage = null; yakuCatUpdateUsage(); return Promise.resolve(null); }
    var request = ++yakuCatUsageRequest;
    return yakuCatPost('estimate', { id: yakuCatProjectId }).then(function (usage) {
      if (request !== yakuCatUsageRequest) return usage;
      yakuCatUsage = usage || null;
      yakuCatUpdateUsage();
      return usage;
    }).catch(function () {
      return null;
    });
  }

  function yakuCatUpdateProgress(data) {
    var row = document.getElementById('cat-progress-row');
    if (!row) return;
    row.hidden = false;
    // 進捗は「人が確認した数」で出す。機械が埋めた数だと、翻訳ボタンを
    // 押した瞬間に 100% になり、以後どれだけ確認しても動かない。
    // 数百行を何時間もかけて見る作業では、それは進捗として役に立たない。
    var total = data.total || 0;
    var confirmed = data.confirmed || 0;
    var filled = data.translated || 0;
    var pct = total ? Math.round((confirmed / total) * 100) : 0;
    var bar = document.getElementById('cat-progress-bar');
    if (bar) bar.style.width = pct + '%';
    var meter = row.querySelector('[role="progressbar"]');
    if (meter) meter.setAttribute('aria-valuenow', pct);
    var text = document.getElementById('cat-progress-text');
    // 機械が埋めた数も併記する。訳が入っているかと、見たかは別の話なので。
    // 数字だけでは伝わらない。いま何が残っているかを言葉で書く。
    var left = total - confirmed;
    if (text) text.textContent = left > 0
      ? ('全 ' + total + ' 行のうち ' + confirmed + ' 行を確認しました。残り ' + left + ' 行です。')
      : ('全 ' + total + ' 行の確認が終わりました。');
    var currentProgress = document.getElementById('cat-current-progress');
    if (currentProgress) currentProgress.textContent = left > 0
      ? ('全 ' + total + ' 行のうち ' + confirmed + ' 行を確認済み・残り ' + left + ' 行')
      : ('全 ' + total + ' 行の確認が終わりました');
  }

  function yakuCatPost(action, payload) {
    payload = payload || {};
    if (payload.id && yakuCatData && yakuCatData.id === payload.id && typeof payload.expected_revision === 'undefined') {
      payload.expected_revision = Number(yakuCatData.revision) || 0;
    }
    return yakuJsonPost('/api/cat/' + action, payload).then(function (response) {
      return response.text().then(function (text) {
        var data = null;
        try { data = JSON.parse(text); } catch (e) { data = null; }
        if (!response.ok) throw new Error(yakuUserFacingError((data && data.error) ? data.error : text));
        return data;
      });
    });
  }

  function yakuCatSourceMode() {
    var checked = document.querySelector('input[name="cat_source"]:checked');
    return checked ? checked.value : 'text';
  }

  function yakuCatSource() {
    // 貼り付けからも始められる。簡易翻訳と入力の作法を揃えるため。
    if (yakuCatSourceMode() === 'text') {
      var area = document.getElementById('cat-text');
      var text = area ? area.value : '';
      if (!text.trim()) return Promise.reject(new Error('翻訳したいテキストを貼り付けてください。'));
      return Promise.resolve({ text: text });
    }
    // ファイル翻訳と同じ入口を使う。アップロードかローカルパスのどちらか。
    var input = document.getElementById('cat-file-input');
    var path = document.getElementById('cat-path');
    if (input && input.files && input.files.length) {
      var file = input.files[0];
      var fingerprint = yakuFileFingerprint(file);
      if (yakuCatUploaded && yakuCatUploaded.fingerprint === fingerprint) return Promise.resolve({ file_handle: yakuCatUploaded.handle });
      return yakuFetch('/api/upload', {
        method: 'POST',
        headers: { 'Content-Type': 'application/octet-stream', 'X-Yaku-File-Name': encodeURIComponent(file.name) },
        body: file
      }).then(yakuResponseJson).then(function (data) {
        if (!data.file_handle) throw new Error('アップロードハンドルを取得できませんでした。');
        yakuCatUploaded = { fingerprint: fingerprint, handle: data.file_handle };
        return { file_handle: data.file_handle };
      });
    }
    if (path && path.value.trim()) return Promise.resolve({ file_path: path.value.trim() });
    return Promise.reject(new Error('ファイルを選択するか、ローカルパスを入力してください。'));
  }

  function yakuCatUpdateMainResume() {
    var mainResume = document.getElementById('open-resume-workspace');
    if (!mainResume) return;
    if (yakuCatProjectId && yakuCatData) {
      mainResume.hidden = false;
      mainResume.textContent = '確認作業に戻る';
      mainResume.setAttribute('data-yaku-current-project', yakuCatProjectId);
      mainResume.removeAttribute('data-yaku-resume-id');
      return;
    }
    mainResume.removeAttribute('data-yaku-current-project');
    if (yakuCatRecentProjects.length === 1) {
      mainResume.textContent = '前回の翻訳作業を続ける';
      mainResume.setAttribute('data-yaku-resume-id', yakuCatRecentProjects[0].id || '');
    } else {
      mainResume.textContent = '保存した作業を選ぶ（' + yakuCatRecentProjects.length + '件）';
      mainResume.removeAttribute('data-yaku-resume-id');
    }
  }

  function yakuCatSavedLabel(project) {
    var direction = project.direction === 'to_jp' ? '英語などから日本語' : '日本語から英語';
    var remaining = Math.max(0, (Number(project.total) || 0) - (Number(project.confirmed) || 0));
    var saved = '';
    try {
      var date = new Date(project.saved);
      if (!isNaN(date.getTime())) saved = date.toLocaleString('ja-JP', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' });
    } catch (e) {}
    return (project.file_name || '名称未設定') + '・' + direction + '・' + (remaining ? ('あと' + remaining + '行') : '確認完了') + (saved ? ('・' + saved) : '');
  }

  // 前回の続きを出す。閉じても再起動しても戻せることを、目に見える形にする。
  function yakuCatLoadRecent() {
    yakuCatPost('recent', {}).then(function (data) {
      var box = document.getElementById('cat-resume');
      var list = document.getElementById('cat-resume-list');
      var mainResume = document.getElementById('open-resume-workspace');
      if (!box || !list) return;
      var items = (data.projects || []).filter(function (p) { return p.total > 0; });
      yakuCatRecentProjects = items;
      if (!items.length) {
        box.hidden = true;
        if (mainResume && !(yakuCatProjectId && yakuCatData)) mainResume.hidden = true;
        yakuCatUpdateMainResume();
        return;
      }
      box.hidden = false;
      if (mainResume) mainResume.hidden = false;
      list.innerHTML = items.slice(0, 10).map(function (p, index) {
        return '<button type="button" class="cat-resume-card" data-yaku-cat-resume="' + yakuEscape(p.id) + '">' +
          (index === 0 ? '<span class="cat-resume-recent">前回開いた作業</span>' : '') + yakuEscape(yakuCatSavedLabel(p)) + '</button>';
      }).join('');
      yakuCatUpdateMainResume();
    }).catch(function () {
      var box = document.getElementById('cat-resume');
      var list = document.getElementById('cat-resume-list');
      if (box && list) {
        box.hidden = false;
        list.innerHTML = '<div class="alert alert-error">保存した作業を読み込めませんでした。少し待ってから「文章を訳す画面へ戻る」を押し、もう一度お試しください。</div>';
      }
    });
  }

  function yakuCatResume(id, editsFlushed) {
    if (yakuTranslating) { yakuCatSetStatus('処理中は別の作業を開けません。'); return Promise.resolve(null); }
    if (!editsFlushed) return yakuCatAfterFlush(function () { return yakuCatResume(id, true); });
    var request = ++yakuCatViewRequest;
    yakuCatFocusFirstAfterRender = true;
    yakuCatSetStatus('前回の作業を読み込んでいます…');
    return yakuCatPost('resume', { project_id: id }).then(function (data) {
      if (request !== yakuCatViewRequest) return;
      yakuCatRender(data);
    }).catch(function (error) {
      if (request !== yakuCatViewRequest) return;
      yakuCatSetStatus('前回の作業を読み込めませんでした: ' + (error && error.message ? error.message : ''));
    });
  }

  function yakuCatOpen(existingTranslation, editsFlushed) {
    if (yakuTranslating) { yakuCatSetStatus('処理中は新しい作業を始められません。'); return Promise.resolve(null); }
    if (!editsFlushed) return yakuCatAfterFlush(function () { return yakuCatOpen(existingTranslation, true); });
    var request = ++yakuCatViewRequest;
    var checked = document.querySelector('input[name="cat_direction"]:checked');
    yakuCatSetStatus('取り込んでいます…');
    return yakuCatSource().then(function (source) {
      source.direction = checked ? checked.value : 'to_en';
      // 簡易翻訳から渡された訳文があれば一緒に送る。
      // 開いた瞬間に原文と訳文が並ぶので、押すボタンがゼロで確認に入れる。
      if (existingTranslation) { source.translation = existingTranslation; }
      return yakuCatPost('open', source);
    }).then(function (data) {
      if (request !== yakuCatViewRequest) { yakuCatLoadRecent(); return; }
      yakuCatRender(data);
    }).catch(function (error) {
      if (request !== yakuCatViewRequest) return;
      yakuCatSetStatus('取り込めませんでした: ' + (error && error.message ? error.message : ''));
    });
  }

  function yakuCatOpenPriorVersion(editsFlushed) {
    if (yakuTranslating) { yakuCatSetStatus('処理中は新しい作業を始められません。'); return Promise.resolve(null); }
    if (!editsFlushed) return yakuCatAfterFlush(function () { return yakuCatOpenPriorVersion(true); });
    var request = ++yakuCatViewRequest;
    var current = document.getElementById('cat-current-ja');
    var priorJa = document.getElementById('cat-prior-ja');
    var priorEn = document.getElementById('cat-prior-en');
    var name = document.getElementById('cat-prior-name');
    var currentText = current ? current.value : '';
    var priorJaText = priorJa ? priorJa.value : '';
    var priorEnText = priorEn ? priorEn.value : '';
    if (!currentText.trim()) { yakuCatSetStatus('今回の日本語を貼り付けてください。'); if (current) current.focus(); return; }
    if (!!priorJaText.trim() !== !!priorEnText.trim()) { yakuCatSetStatus('前回の資料は日本語と英語を両方貼り付けてください。'); return; }
    yakuCatSetStatus('前回と今回を比べています…');
    return yakuCatPost('from-prior-version', {
      current_ja: currentText,
      prior_ja: priorJaText,
      prior_en: priorEnText,
      document_name: name ? name.value.trim() : ''
    }).then(function (data) {
      if (request !== yakuCatViewRequest) { yakuCatLoadRecent(); return; }
      yakuCatRender(data);
    }).catch(function (error) {
      if (request !== yakuCatViewRequest) return;
      yakuCatSetStatus('前回の資料を使った作業を始められませんでした: ' + (error && error.message ? error.message : ''));
    });
  }

  function yakuCatGlossary(editsFlushed) {
    if (!yakuCatProjectId) return;
    if (yakuTranslating) { yakuCatSetStatus('処理中は用語集を適用できません。'); return Promise.resolve(null); }
    if (!editsFlushed) return yakuCatAfterFlush(function () { return yakuCatGlossary(true); });
    yakuCatSetStatus('用語集で置換しています…');
    return yakuCatPost('glossary', { id: yakuCatProjectId }).then(yakuCatRender).catch(function (error) {
      yakuCatSetStatus('置換できませんでした: ' + (error && error.message ? error.message : ''));
    });
  }

  function yakuCatTranslate(mode, editsFlushed) {
    if (!yakuCatProjectId) {
      yakuCatSetStatus('先に原文を取り込んでください。');
      return;
    }
    if (!editsFlushed) {
      return yakuCatAfterFlush(function () { return yakuCatTranslate(mode, true); });
    }
    // 黙って戻らない。何も起きない画面は、壊れているのと区別が付かない。
    if (yakuTranslating) {
      yakuCatSetStatus('いま別の処理を実行しています。終わってからもう一度お試しください。');
      return;
    }
    if (!yakuReady) {
      yakuCatSetStatus('Copilotの準備ができるまでお待ちください。準備できると自動でボタンが使えるようになります。');
      yakuPollReadyState();
      return;
    }
    var requestedMode = mode || 'translate';
    // 概算の再取得中も二重起動を防ぐ。応答を待つ数百msだけ無防備だと、
    // ダブルクリックで同じ残りを2ジョブへ送ってしまう。
    yakuTranslating = true;
    yakuCatJobProjectId = yakuCatProjectId;
    yakuCatJobProjectRevision = yakuCatData ? (Number(yakuCatData.revision) || 0) : 0;
    yakuActiveJobKind = 'cat';
    yakuSetButtonEnabled(false);
    var beforeStart = requestedMode === 'translate' ? yakuCatRefreshUsage() : Promise.resolve(null);
    return beforeStart.then(function () {
      yakuRenderJobLoading('', 0, requestedMode === 'corpus' ? '参考文例を準備中' : 'Copilotで翻訳中', '準備中');
      yakuScrollJobResultIntoView();
      // ジョブは別のランスペースで走る。各成功バッチはチェックポイントへ
      // 保存し、完了後の apply では最終結果を取り込む。
      return yakuJsonPost('/api/cat/translate', { id: yakuCatJobProjectId, mode: requestedMode, expected_revision: yakuCatJobProjectRevision }).then(yakuResponseText).then(yakuStartFromHtml);
    }).catch(function (error) {
      yakuCatJobProjectId = '';
      yakuCatJobProjectRevision = -1;
      yakuShowStartError(error, requestedMode === 'corpus' ? '参考文例を表示できませんでした。' : 'Copilot翻訳を開始できませんでした。');
    });
  }

  function yakuCatRevise(form, editsFlushed) {
    if (!yakuCatProjectId || !form) return;
    var input = form.querySelector('.revise-input');
    var instruction = input ? input.value.trim() : '';
    var index = parseInt(form.getAttribute('data-yaku-cat-revise'), 10);
    if (!instruction) { if (input) input.focus(); return; }
    if (!editsFlushed) {
      return yakuCatAfterFlush(function () { return yakuCatRevise(form, true); });
    }
    if (yakuTranslating) {
      yakuCatSetStatus('いま別の処理を実行しています。終わってからもう一度お試しください。');
      return;
    }
    if (!yakuReady) { yakuPollReadyState(); return; }
    yakuTranslating = true;
    yakuCatJobProjectId = yakuCatProjectId;
    yakuCatJobProjectRevision = yakuCatData ? (Number(yakuCatData.revision) || 0) : 0;
    yakuActiveJobKind = 'cat';
    yakuSetButtonEnabled(false);
    yakuRenderJobLoading('', 0, '修正を依頼中', '準備中');
    yakuScrollJobResultIntoView();
    return yakuJsonPost('/api/cat/translate', {
      id: yakuCatJobProjectId,
      mode: 'revise',
      index: index,
      instruction: instruction,
      expected_revision: yakuCatJobProjectRevision
    }).then(yakuResponseText).then(yakuStartFromHtml).catch(function (error) {
      yakuCatJobProjectId = '';
      yakuCatJobProjectRevision = -1;
      yakuShowStartError(error, '修正を依頼できませんでした。');
    });
  }

  function yakuCatApply(jobId, projectId, projectRevision) {
    projectId = projectId || yakuCatProjectId;
    if (!projectId || !jobId) return;
    yakuCatSetStatus('訳文を取り込んでいます…');
    return yakuCatPost('apply', { id: projectId, job_id: jobId, expected_revision: Number(projectRevision) || 0 }).then(function (data) {
      if (yakuCatProjectId === projectId) yakuCatRender(data);
      else yakuCatLoadRecent();
      return data;
    }).catch(function (error) {
      if (yakuCatProjectId === projectId) yakuCatSetStatus('訳文を取り込めませんでした: ' + (error && error.message ? error.message : ''));
    });
  }

  // 既にある訳と突き合わせる。数分かかるのでジョブで走らせ、
  // 終わったら対を受け取ってグリッドを組み立てる。
  function yakuCatAlign(editsFlushed) {
    if (!editsFlushed) return yakuCatAfterFlush(function () { return yakuCatAlign(true); });
    yakuCatAlignRequest = ++yakuCatViewRequest;
    var src = document.getElementById('cat-align-source');
    var tgt = document.getElementById('cat-align-target');
    var name = document.getElementById('cat-align-name');
    var dir = document.querySelector('input[name="cat_direction"]:checked');
    if (!src || !tgt || !src.value.trim() || !tgt.value.trim()) {
      yakuCatSetStatus('原文と訳文の両方を貼り付けてください。');
      return;
    }
    yakuCatProjectId = null;
    yakuCatAligning = true;
    yakuRenderJobLoading('', 0, '対訳を突き合わせ中', '準備中');
    yakuCatSetStatus('突き合わせています…（数分かかります）');
    // 他のジョブ開始と同じ道を通す。ここだけ独自に書いて、
    // 存在しない関数名（yakuPostJson）と、HTML を jobId として渡す誤りを
    // 同時に入れていた。押した瞬間に落ち、しかも同期例外なので catch にも
    // 入らず「数分かかります」と出たまま止まっていた（2026-08-08 に判明）。
    return yakuJsonPost('/api/cat/align', {
      direction: dir ? dir.value : 'to_en',
      source_text: src.value,
      target_text: tgt.value,
      file_name: name ? name.value : ''
    }).then(yakuResponseText).then(yakuStartFromHtml).catch(function (error) {
      // 落ちたら待ち状態を必ず解く。解かないと、次に普通の翻訳をしたとき
      // その結果が突き合わせの結果として扱われ、グリッドが壊れる。
      yakuCatAligning = false;
      yakuCatSetStatus('突き合わせを開始できませんでした。');
      yakuShowStartError(error, '突き合わせを開始できませんでした。');
    });
  }

  function yakuCatAlignApply(jobId) {
    if (!jobId) return;
    var request = yakuCatAlignRequest;
    var name = document.getElementById('cat-align-name');
    var dir = document.querySelector('input[name="cat_direction"]:checked');
    yakuCatSetStatus('対応を取り込んでいます…');
    return yakuCatPost('align-apply', {
      job_id: jobId,
      direction: dir ? dir.value : 'to_en',
      file_name: name ? name.value : ''
    }).then(function (data) {
      if (request !== yakuCatViewRequest) { yakuCatLoadRecent(); return; }
      yakuCatRender(data);
    }).catch(function (error) {
      if (request !== yakuCatViewRequest) return;
      yakuCatSetStatus('対応を取り込めませんでした: ' + (error && error.message ? error.message : ''));
    });
  }

  // 確かめた対訳を文例として貯める。押すまで貯まらない。
  function yakuCatSaveCorpus(editsFlushed) {
    if (!yakuCatProjectId) return;
    if (yakuTranslating) { yakuCatSetStatus('処理中は文例を保存できません。'); return Promise.resolve(null); }
    if (!editsFlushed) return yakuCatAfterFlush(function () { return yakuCatSaveCorpus(true); });
    var name = document.getElementById('cat-align-name');
    var database = window.prompt('どの資料の文例として保存しますか（例: 有報、決算短信）', (name && name.value) ? name.value : '対訳');
    if (!database) return;
    yakuCatSetStatus('文例として保存しています…');
    yakuCatPost('save-corpus', { id: yakuCatProjectId, database: database }).then(function (data) {
      yakuCatSetStatus('文例として保存しました：' + (data.added || 0) + '組を追加、' + (data.skipped || 0) + '組は登録済みでした。');
    }).catch(function (error) {
      yakuCatSetStatus('登録できませんでした: ' + (error && error.message ? error.message : ''));
    });
  }

  function yakuCatExport(editsFlushed) {
    if (!yakuCatProjectId) return;
    if (yakuTranslating) { yakuCatSetStatus('処理中は出力できません。'); return Promise.resolve(null); }
    if (!editsFlushed) {
      return yakuCatAfterFlush(function () { return yakuCatExport(true); });
    }
    yakuCatClearOutputDisplay();
    yakuCatSetStatus('出力しています…');
    return yakuCatPost('export', { id: yakuCatProjectId }).then(function (data) {
      // 貼り付けたテキストは書き戻す元が無いので、繋いだ訳文をクリップボードへ。
      // 簡易翻訳と同じ終わり方にして、覚えることを増やさない。
      if (data.text) {
        var textPanel = document.getElementById('cat-text-output');
        var textValue = document.getElementById('cat-text-output-value');
        if (textPanel) textPanel.hidden = false;
        if (textValue) textValue.value = data.text;
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(data.text).then(function () {
            yakuCatSetStatus('訳文をコピーしました（' + data.written + '件）。全文は下の欄にも残しています。');
          }, function () {
            yakuCatSetStatus('コピーできませんでした。下の「確認済み訳文」に全文を残しました。「もう一度コピー」または「全文を選択」を使ってください。');
            if (textValue) { textValue.focus(); textValue.select(); }
          });
        } else {
          yakuCatSetStatus('コピー機能を使えません。下の「確認済み訳文」に全文を残しました。「全文を選択」を使ってください。');
          if (textValue) { textValue.focus(); textValue.select(); }
        }
        return;
      }
      // パスの文字列だけでは、成果物に辿り着けない。
      // ~/.yakulingo-ps は、この利用者が一生自力では開かないフォルダである。
      var openRow = document.getElementById('cat-output-row');
      var nameEl = document.getElementById('cat-output-name');
      if (openRow && nameEl) {
        openRow.hidden = false;
        nameEl.textContent = data.output_name || data.output_path;
        yakuCatOutputProjectId = yakuCatProjectId;
        yakuCatOutputRevision = yakuCatData ? (Number(yakuCatData.revision) || 0) : 0;
        openRow.setAttribute('data-yaku-output-project', yakuCatOutputProjectId);
        openRow.setAttribute('data-yaku-output-revision', String(yakuCatOutputRevision));
      }
      yakuCatSetStatus('確認用DRAFTを作成しました。完成版ではなく、社外配布できません。下の「フォルダを開く」で場所を開けます。');
      var warning = document.getElementById('cat-draft-warning');
      if (warning) {
        warning.hidden = false;
        warning.textContent = '確認用DRAFTを作成しました。完成版ではありません。社外配布しないでください。';
        warning.focus();
      }
    }).catch(function (error) {
      yakuCatSetStatus('出力できませんでした: ' + (error && error.message ? error.message : ''));
    });
  }

  // 候補ペイン。用語集は手元で引けるので、行を移るたびに出せる。
  var yakuCatCandidateSeq = 0;

  function yakuCatLoadCandidates(index) {
    if (!yakuCatProjectId || isNaN(index)) return;
    var seq = ++yakuCatCandidateSeq;
    yakuCatPost('candidates', { id: yakuCatProjectId, index: index }).then(function (data) {
      // 行を早く移ったときに、古い応答で上書きしない。
      if (seq !== yakuCatCandidateSeq) return;
      var panel = document.getElementById('cat-candidates');
      var list = document.getElementById('cat-candidates-list');
      if (!panel || !list) return;
      var items = data.candidates || [];
      panel.hidden = false;
      if (!items.length) {
        list.innerHTML = '<div class="muted">この行に当たる用語・文例はありません。</div>';
        return;
      }
      list.innerHTML = items.map(function (c, i) {
        // 用語集は、完全一致か文中の一致かを区別する。完全一致は機械置換の
        // 対象で、文中の語は置換しない（活用と一致が壊れるため）。目に入れるだけ。
        // 過去の対訳は一致率で出す。市販ツールの翻訳メモリと同じ読み方になる。
        // 翻訳メモリは自分が確定した訳。公表訳の文例とは値打ちが違うので
        // 見た目でも分ける。市販ツールが 100% 一致を別格に扱うのと同じ。
        var tag;
        if (c.kind === 'memory') {
          tag = c.exact ? '自分の訳 100%' : '自分の訳 ' + Math.round((c.ratio || 0) * 100) + '%';
        } else if (c.kind === 'corpus') {
          tag = c.exact ? '公表訳 100%' : '公表訳 ' + Math.round((c.ratio || 0) * 100) + '%';
        } else {
          tag = c.exact ? '用語集（完全一致）' : '用語集（文中）';
        }
        if (c.database) tag += ' / ' + String(c.database);
        return '<button type="button" class="cat-cand" data-yaku-cat-insert="' + yakuEscape(c.target) + '">' +
          '<span class="cat-cand-no">' + (i + 1) + '</span>' +
          '<span class="cat-cand-tag' + (c.exact ? ' is-exact' : '') + '">' + yakuEscape(tag) + '</span>' +
          '<span class="cat-cand-src">' + yakuEscape(c.source) + '</span>' +
          '<span class="cat-cand-tgt">' + yakuEscape(c.target) + '</span>' +
          '</button>';
      }).join('');
      if (yakuTranslating) yakuSetButtonEnabled(false);
    }).catch(function () {});
  }

  function yakuCatInsert(input, text) {
    if (!input || !text) return;
    if (yakuTranslating || yakuCatOperationBusy) {
      yakuCatSetStatus('処理中は訳文を変更できません。完了してからお試しください。');
      return;
    }
    // 空なら丸ごと入れる。書きかけならカーソル位置へ差し込む。
    if (!input.value.trim()) { input.value = text; }
    else {
      var at = (typeof input.selectionStart === 'number') ? input.selectionStart : input.value.length;
      input.value = input.value.slice(0, at) + text + input.value.slice(at);
      input.selectionStart = input.selectionEnd = at + text.length;
    }
    yakuCatMarkDirty(input);
    input.focus();
  }

  function yakuCatRegroup(action, index, editsFlushed) {
    if (!yakuCatProjectId) return;
    if (yakuTranslating) { yakuCatSetStatus('処理中は行を結合・解除できません。'); return Promise.resolve(null); }
    if (!editsFlushed) return yakuCatAfterFlush(function () { return yakuCatRegroup(action, index, true); });
    yakuCatSetStatus(action === 'merge' ? '結合しています…' : '解除しています…');
    return yakuCatPost(action, { id: yakuCatProjectId, index: index }).then(yakuCatRender).catch(function (error) {
      yakuCatSetStatus('変更できませんでした: ' + (error && error.message ? error.message : ''));
    });
  }

  function yakuCatSaveSegment(projectId, index, text) {
    if (!projectId) return Promise.reject(new Error('作業が開かれていません。'));
    return yakuCatPost('segment', { id: projectId, index: index, text: text }).then(function (data) {
      // 別の作業へ移った後に届いた保存応答は、その作業の保存成功としてだけ扱う。
      // 現在画面のproject、進捗、行表示へは絶対に混ぜない。
      if (yakuCatProjectId !== projectId || !data || data.id !== projectId) return data;
      // 全体を描き直すと編集中のカーソルが飛ぶので、その行と件数だけ更新する。
      yakuCatData = data;
      yakuCatSetStatus(data.file_name + ' … ' + data.total + ' 行（訳あり ' + data.translated + ' / 残り ' + data.remaining + '、結合 ' + data.joined + '）');
      yakuCatUpdateProgress(data);
      // 用語集で埋められる行数を、押す前に出す。
      var gcount = document.getElementById('cat-glossary-count');
      if (gcount) gcount.textContent = (data.glossary_candidates > 0) ? ('（' + data.glossary_candidates + ' 行）') : '';
      var grun = document.getElementById('cat-glossary-button');
      if (grun) grun.disabled = !(data.glossary_candidates > 0);
      var tr = document.querySelector('[data-yaku-cat-row="' + index + '"]');
      if (tr) {
        tr.setAttribute('data-yaku-cat-state', text.trim() ? 'human_edited' : 'untranslated');
        var badge = tr.querySelector('.cat-col-loc .cat-origin');
        if (text.trim()) {
          if (!badge) {
            badge = document.createElement('span');
            tr.querySelector('.cat-col-loc').insertBefore(badge, tr.querySelector('.cat-ops'));
          }
          badge.className = 'cat-origin cat-origin-manual';
          badge.textContent = '手直し';
        } else if (badge) {
          badge.remove();
        }
        tr.setAttribute('data-yaku-confirmed', '0');
        var editedInput = tr.querySelector('[data-yaku-cat-input]');
        if (editedInput) {
          editedInput.setAttribute('aria-invalid', 'false');
          editedInput.removeAttribute('aria-describedby');
          editedInput.setAttribute('aria-label', (index + 1) + '行目の訳文・手編集・未確認');
        }
        var oldFinding = tr.querySelector('.cat-qc-findings');
        if (oldFinding) oldFinding.remove();
      }
      return data;
    }).catch(function (error) {
      if (yakuCatProjectId !== projectId) throw error;
      // 黙って捨てない。捨てると、その行は「保存済み」と見なされて
      // 二度と送られない。直した内容が消えたことに誰も気づけない。
      var tr = document.querySelector('[data-yaku-cat-row="' + index + '"]');
      if (tr) tr.classList.add('cat-unsaved');
      var input = document.querySelector('[data-yaku-cat-input="' + index + '"]');
      // 保存できていないので「元の値」を戻す。次の機会に送り直せるようにする。
      if (input) input.removeAttribute('data-yaku-original');
      yakuCatSetStatus((index + 1) + '行目を保存できませんでした: ' + (error && error.message ? error.message : '') + '（この行は赤く表示しています）');
      throw error;
    });
  }

  function yakuFileFingerprint(file) {
    return [file.name, file.size, file.lastModified].join(':');
  }

  function yakuEnsureFileSource() {
    var fileInput = document.getElementById('file-input');
    var pathInput = document.getElementById('file-path');
    if (fileInput && fileInput.files && fileInput.files.length) {
      var file = fileInput.files[0];
      if (!file.size) return Promise.reject(new Error('空のファイルはアップロードできません。'));
      if (file.size > fileMaxBytes) return Promise.reject(new Error('ファイルサイズが上限 ' + yakuFormatBytes(fileMaxBytes) + ' を超えています。'));
      var fingerprint = yakuFileFingerprint(file);
      if (yakuUploadedFile && yakuUploadedFile.fingerprint === fingerprint) return Promise.resolve({ file_handle: yakuUploadedFile.handle });
      yakuUpdateFileMeta('ファイルを安全にアップロードしています（' + yakuFormatBytes(file.size) + '）');
      return yakuFetch('/api/upload', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/octet-stream',
          'X-Yaku-File-Name': encodeURIComponent(file.name)
        },
        body: file
      }).then(yakuResponseJson).then(function (data) {
        if (!data.file_handle) throw new Error('アップロードハンドルを取得できませんでした。');
        yakuUploadedFile = { fingerprint: fingerprint, handle: data.file_handle };
        return { file_handle: data.file_handle };
      });
    }
    if (pathInput && pathInput.value.trim()) return Promise.resolve({ file_path: pathInput.value.trim() });
    return Promise.reject(new Error('翻訳するファイルを選択してください。'));
  }

  function yakuSelectedSheets() {
    if (Array.isArray(yakuSheetSelection)) return yakuSheetSelection.slice();
    var input = document.getElementById('file-sheets');
    if (!input || !input.value.trim()) return [];
    return input.value.split(/[\n,、]+/).map(function (value) { return value.trim(); }).filter(Boolean);
  }

  function yakuBuildFilePayload() {
    return yakuEnsureFileSource().then(function (source) {
      var direction = document.querySelector('input[name="file_direction"]:checked');
      source.direction = direction ? direction.value : 'to_en';
      source.sheets = yakuSelectedSheets();
      return source;
    });
  }

  function yakuSubmitFileInfo() {
    if (!yakuHasFileSource() || yakuTranslating) return;
    yakuUpdateFileMeta('ファイル内容を確認しています');
    yakuBuildFilePayload().then(function (payload) {
      return yakuJsonPost('/api/file-info', payload).then(yakuResponseJson);
    }).then(function (data) {
      var sheets = data.Sheets || [];
      var chips = sheets.map(function (sheet) {
        var name = sheet.Name || '';
        var title = name + ' / UsedRange ' + (sheet.UsedRange || '-') + ' / 図形 ' + (sheet.ShapeCount || 0) + ' / グラフ ' + (sheet.ChartCount || 0);
        return '<button type="button" class="sheet-chip is-selected" aria-pressed="true" data-yaku-sheet="' + yakuEscape(name) + '" title="' + yakuEscape(title) + '">' + yakuEscape(name) + '</button>';
      }).join('');
      var detected = data.DetectedDirection === 'to_en' ? '日→英' : (data.DetectedDirection === 'to_jp' ? '英語など→日本語' : '-');
      var reflected = false;
      if (!yakuFileDirectionTouched && ['to_en', 'to_jp'].indexOf(data.DetectedDirection) >= 0) {
        var detectedRadio = document.querySelector('input[name="file_direction"][value="' + data.DetectedDirection + '"]');
        if (detectedRadio) { detectedRadio.checked = true; reflected = true; }
      }
      var sheetInput = document.getElementById('file-sheets');
      yakuSheetSelection = sheets.map(function (sheet) { return String(sheet.Name || ''); }).filter(Boolean);
      if (sheetInput) sheetInput.value = yakuSheetSelection.join(', ');
      var reflectedText = reflected ? ' / 推定方向を反映しました' : '';
      var warning = '<div id="sheet-selection-warning" class="alert-inline" hidden>対象シートが選択されていません。チップを選択するか、対象シート欄を空欄に戻すと全シートが対象になります。</div>';
      yakuUpdateFileMeta('<strong>確認OK</strong>：' + yakuEscape(data.FileName || '') + ' / 推定方向 ' + detected + reflectedText + (chips ? '<div class="sheet-chip-row" aria-label="対象シート">' + chips + '</div>' + warning : ''));
      yakuUpdateFileButton();
    }).catch(function (error) {
      yakuUpdateFileMeta('<span class="alert-inline">' + yakuEscape(error.message || 'ファイル確認に失敗しました。') + '</span>');
    });
  }

  function yakuActivateTab(name) {
    var target = (name === 'file' || name === 'cat') ? name : 'text';
    yakuActiveTab = target;
    document.querySelectorAll('[data-yaku-panel]').forEach(function (panel) {
      var active = panel.getAttribute('data-yaku-panel') === target;
      panel.hidden = !active;
      panel.classList.toggle('is-active', active);
      panel.classList.toggle('active', active);
    });
    if (!yakuTranslating) {
      var result = yakuGetResultTarget();
      if (result) { result.innerHTML = yakuResultByTab[target] || yakuEmptyResultHtml(); yakuNotifyResultRendered(); }
    }
  }

  function yakuOpenWorkspace(mode, editsFlushed) {
    if (!editsFlushed) return yakuCatAfterFlush(function () { return yakuOpenWorkspace(mode, true); });
    if (mode === 'resume' && !(yakuCatProjectId && yakuCatData) && yakuCatRecentProjects.length === 1) {
      yakuActivateTab('cat');
      return yakuCatResume(yakuCatRecentProjects[0].id, true);
    }
    if (mode !== 'resume') {
      var radio = document.querySelector('input[name="cat_source"][value="' + mode + '"]');
      if (radio) {
        radio.checked = true;
        radio.dispatchEvent(new Event('change', { bubbles: true }));
      }
    }
    ++yakuCatViewRequest;
    yakuActivateTab('cat');
    window.setTimeout(function () {
      var target = null;
      if (mode === 'resume' && yakuCatProjectId && yakuCatData) {
        target = document.querySelector('[data-yaku-cat-row][data-yaku-confirmed="0"] [data-yaku-cat-input]') || document.querySelector('[data-yaku-cat-input]');
      } else if (mode === 'resume') target = document.querySelector('#cat-resume-list [data-yaku-cat-resume]');
      else if (mode === 'file') target = document.getElementById('cat-drop');
      else if (mode === 'align') target = document.getElementById('cat-align-source');
      else if (mode === 'prior') target = document.getElementById('cat-prior-ja');
      else target = document.getElementById('cat-text');
      if (target) {
        target.focus();
        target.scrollIntoView({ behavior: yakuScrollBehavior(), block: 'center' });
      }
    }, 0);
  }

  function yakuDownload(jobId, button) {
    button.disabled = true;
    yakuFetch('/api/download?job_id=' + encodeURIComponent(jobId)).then(function (response) {
      if (!response.ok) return response.text().then(function (text) { throw new Error(text || 'ダウンロードに失敗しました。'); });
      var disposition = response.headers.get('Content-Disposition') || '';
      var encodedMatch = disposition.match(/filename\*=UTF-8''([^;]+)/i);
      var plainMatch = disposition.match(/filename="?([^";]+)"?/i);
      var fileName = 'YakuLingo_output';
      if (encodedMatch) { try { fileName = decodeURIComponent(encodedMatch[1]); } catch (_) { fileName = encodedMatch[1]; } }
      else if (plainMatch) { fileName = plainMatch[1]; }
      return response.blob().then(function (blob) {
        var url = URL.createObjectURL(blob);
        var link = document.createElement('a');
        link.href = url;
        link.download = fileName;
        document.body.appendChild(link);
        link.click();
        link.remove();
        window.setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
      });
    }).catch(function (error) {
      window.alert(error.message || 'ダウンロードに失敗しました。');
    }).finally(function () { button.disabled = false; });
  }

  function yakuCopy(button) {
    var text = button.getAttribute('data-yaku-copy-b64') ? yakuDecodeB64(button.getAttribute('data-yaku-copy-b64')) : (button.getAttribute('data-yaku-copy') || '');
    var original = button.textContent;
    var done = function () {
      button.textContent = 'コピー済み';
      window.setTimeout(function () { button.textContent = original; }, 1400);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done).catch(function () {});
    else {
      var temp = document.createElement('textarea');
      temp.value = text;
      document.body.appendChild(temp);
      temp.select();
      try { document.execCommand('copy'); done(); } catch (ignore) {}
      temp.remove();
    }
  }

  function yakuApplyTextSize(large) {
    document.documentElement.setAttribute('data-yaku-text-size', large ? 'large' : 'standard');
    var button = document.getElementById('text-size-toggle');
    if (button) {
      button.setAttribute('aria-pressed', large ? 'true' : 'false');
      button.textContent = large ? '標準の文字に戻す' : '文字を大きく';
    }
  }

  function yakuBindEvents() {
    var textForm = document.getElementById('text-form');
    var inputText = document.getElementById('input-text');
    var fileInput = document.getElementById('file-input');
    var filePath = document.getElementById('file-path');
    var fileSheets = document.getElementById('file-sheets');
    var fileInfoButton = document.getElementById('file-info-button');
    var fileDrop = document.getElementById('file-drop');
    var fileClearButton = document.getElementById('file-clear-button');
    var textSizeToggle = document.getElementById('text-size-toggle');

    if (textSizeToggle) textSizeToggle.addEventListener('click', function () {
      var large = document.documentElement.getAttribute('data-yaku-text-size') !== 'large';
      yakuApplyTextSize(large);
      try { window.localStorage.setItem('yaku-text-size', large ? 'large' : 'standard'); } catch (e) {}
    });

    function yakuBindFileDropTarget(dropTarget, input) {
      if (!dropTarget || !input) return;
      dropTarget.addEventListener('keydown', function (event) {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          input.click();
        }
      });
      ['dragenter', 'dragover'].forEach(function (name) {
        dropTarget.addEventListener(name, function (event) { event.preventDefault(); dropTarget.classList.add('dragover'); });
      });
      ['dragleave', 'drop'].forEach(function (name) {
        dropTarget.addEventListener(name, function (event) { event.preventDefault(); dropTarget.classList.remove('dragover'); });
      });
      dropTarget.addEventListener('drop', function (event) {
        if (event.dataTransfer && event.dataTransfer.files.length) {
          input.files = event.dataTransfer.files;
          input.dispatchEvent(new Event('change'));
        }
      });
    }

    if (textForm) textForm.addEventListener('submit', yakuSubmitText);
    Array.prototype.forEach.call(document.querySelectorAll('input[name="text_direction"]'), function (radio) {
      radio.addEventListener('change', yakuUpdateInputMeta);
    });
    if (inputText) {
      inputText.addEventListener('input', yakuUpdateInputMeta);
      inputText.addEventListener('keydown', function (event) {
        if (event.isComposing || event.keyCode === 229) return;
        if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') {
          event.preventDefault();
          if (textForm && textForm.requestSubmit) textForm.requestSubmit();
        }
      });
    }
    if (fileInput) fileInput.addEventListener('change', function () {
      yakuUploadedFile = null;
      yakuSheetSelection = null;
      yakuFileDirectionTouched = false;
      if (fileInput.files.length && filePath) filePath.value = '';
      yakuResetFileInfoMessage();
    });
    if (filePath) filePath.addEventListener('input', function () {
      if (filePath.value.trim() && fileInput) fileInput.value = '';
      yakuUploadedFile = null;
      yakuSheetSelection = null;
      yakuFileDirectionTouched = false;
      yakuResetFileInfoMessage();
    });
    if (fileInfoButton) fileInfoButton.addEventListener('click', yakuSubmitFileInfo);
    if (fileSheets) fileSheets.addEventListener('input', function () { yakuSheetSelection = null; yakuUpdateFileButton(); });
    Array.prototype.forEach.call(document.querySelectorAll('input[name="file_direction"]'), function (radio) {
      radio.addEventListener('change', function () { yakuFileDirectionTouched = true; });
    });
    if (fileClearButton) fileClearButton.addEventListener('click', function () {
      if (fileInput) fileInput.value = '';
      yakuUploadedFile = null;
      yakuSheetSelection = null;
      yakuFileDirectionTouched = false;
      yakuResetFileInfoMessage();
    });
    yakuBindFileDropTarget(fileDrop, fileInput);

    document.addEventListener('submit', function (event) {
      var catRevise = event.target.closest && event.target.closest('form[data-yaku-cat-revise]');
      if (catRevise) { event.preventDefault(); yakuCatRevise(catRevise); return; }
      var revise = event.target.closest && event.target.closest('form[data-yaku-revise]');
      if (revise) { event.preventDefault(); yakuSubmitRevision(revise); return; }
    });

    // CAT の操作。訳文欄は離れたときに保存する。打つたびに送ると往復が増える。
    var catOpen = document.getElementById('cat-open-button');
    if (catOpen) catOpen.addEventListener('click', function () {
      yakuCatWithOperation(catOpen, function () {
        if (yakuCatSourceMode() === 'align') return yakuCatAlign();
        if (yakuCatSourceMode() === 'prior') return yakuCatOpenPriorVersion();
        return yakuCatOpen();
      });
    });
    var catSaveCorpus = document.getElementById('cat-save-corpus-button');
    if (catSaveCorpus) catSaveCorpus.addEventListener('click', function () { yakuCatSaveCorpus(); });
    var catDelete = document.getElementById('cat-delete-button');
    var catDeleteDialog = document.getElementById('cat-delete-dialog');
    if (catDelete) catDelete.addEventListener('click', function () {
      if (!yakuCatProjectId || yakuCatOperationBusy || yakuTranslating) return;
      yakuCatDeleteTarget = { id: yakuCatProjectId, name: (yakuCatData && yakuCatData.file_name) || 'この翻訳作業' };
      var deleteName = document.getElementById('cat-delete-name');
      if (deleteName) deleteName.textContent = yakuCatDeleteTarget.name;
      if (catDeleteDialog && catDeleteDialog.showModal) {
        catDeleteDialog.returnValue = 'cancel';
        catDeleteDialog.showModal();
        window.setTimeout(function () {
          var cancel = document.getElementById('cat-delete-cancel');
          if (cancel) cancel.focus();
        }, 0);
      }
    });
    if (catDeleteDialog) catDeleteDialog.addEventListener('close', function () {
      var deleteTarget = yakuCatDeleteTarget;
      yakuCatDeleteTarget = null;
      if (catDeleteDialog.returnValue !== 'delete' || !deleteTarget) return;
      if (yakuCatProjectId !== deleteTarget.id) {
        yakuCatSetStatus('表示中の作業が切り替わったため、削除を中止しました。');
        return;
      }
      yakuCatWithOperation(document.getElementById('cat-delete-confirm'), function () { return yakuCatAfterFlush(function () {
        var deletingId = deleteTarget.id;
        return yakuCatPost('delete', { id: deletingId }).then(function () {
          if (yakuCatProjectId !== deletingId) return;
          yakuCatProjectId = '';
          yakuCatData = null;
          yakuCatClearOutputDisplay();
          var body = document.getElementById('cat-grid-body');
          if (body) body.innerHTML = '';
          var wrap = document.getElementById('cat-grid-wrap');
          if (wrap) wrap.hidden = true;
          var actions = document.getElementById('cat-actions');
          if (actions) actions.hidden = true;
          yakuCatSetFocusedMode(false, null);
          yakuCatSetStatus('翻訳作業と途中保存を削除しました。元のファイルは残っています。');
          yakuCatLoadRecent();
          window.setTimeout(function () {
            var start = document.getElementById('cat-open-button');
            if (start) start.focus();
          }, 0);
        }).catch(function (error) { yakuCatSetStatus('作業を削除できませんでした: ' + (error && error.message ? error.message : '')); });
      }); });
    });
    document.addEventListener('click', function (event) {
      var resume = event.target.closest && event.target.closest('[data-yaku-cat-resume]');
      if (resume) yakuCatWithOperation(resume, function () { return yakuCatResume(resume.getAttribute('data-yaku-cat-resume')); });
    });
    // 行のボタン。マウスだけで最後まで進められるようにする。
    document.addEventListener('click', function (event) {
      var ok = event.target.closest && event.target.closest('[data-yaku-cat-ok]');
      if (ok) { yakuCatWithOperation(ok, function () { return yakuCatConfirm(parseInt(ok.getAttribute('data-yaku-cat-ok'), 10)); }); return; }
      var toGlossary = event.target.closest && event.target.closest('[data-yaku-cat-toglossary]');
      if (!toGlossary) return;
      var idx = parseInt(toGlossary.getAttribute('data-yaku-cat-toglossary'), 10);
      yakuCatAfterFlush(function () {
        return yakuCatPost('glossary-add', { id: yakuCatProjectId, index: idx }).then(function (data) {
          yakuCatSetStatus(data.message || '用語集に追加しました。');
        }).catch(function (error) {
          yakuCatSetStatus('用語集に追加できませんでした: ' + (error && error.message ? error.message : ''));
        });
      });
    });
    var catOpenFolder = document.getElementById('cat-open-folder-button');
    if (catOpenFolder) catOpenFolder.addEventListener('click', function () {
      if (!yakuCatProjectId) return;
      yakuJsonPost('/api/open-output', { project_id: yakuCatProjectId }).then(yakuResponseText).then(function () {
        yakuCatSetStatus('フォルダを開きました。');
      }).catch(function (error) {
        yakuCatSetStatus('フォルダを開けませんでした: ' + (error && error.message ? error.message : ''));
      });
    });
    var catSwitchProject = document.getElementById('cat-switch-project');
    if (catSwitchProject) catSwitchProject.addEventListener('click', function () {
      yakuCatAfterFlush(function () {
        var picker = document.getElementById('cat-picker');
        if (picker) picker.hidden = false;
        var summary = document.getElementById('cat-current-summary');
        if (summary) summary.hidden = true;
        var workspace = document.getElementById('cat-workspace');
        if (workspace) workspace.hidden = true;
        var danger = document.getElementById('cat-danger-zone');
        if (danger) danger.hidden = true;
        var resume = document.querySelector('[data-yaku-cat-resume]') || document.querySelector('.cat-source-picker > summary');
        if (resume) resume.focus();
      });
    });
    var catCopyAgain = document.getElementById('cat-copy-again');
    var catSelectAll = document.getElementById('cat-select-all');
    var catTextOutput = document.getElementById('cat-text-output-value');
    if (catCopyAgain) catCopyAgain.addEventListener('click', function () {
      if (!catTextOutput) return;
      var copied = navigator.clipboard && navigator.clipboard.writeText
        ? navigator.clipboard.writeText(catTextOutput.value)
        : Promise.reject(new Error('clipboard unavailable'));
      copied.then(function () { yakuCatSetStatus('確認済み訳文をコピーしました。'); }, function () {
        catTextOutput.focus(); catTextOutput.select();
        yakuCatSetStatus('コピーできませんでした。全文を選択したので、Ctrl+Cでコピーしてください。');
      });
    });
    if (catSelectAll) catSelectAll.addEventListener('click', function () {
      if (!catTextOutput) return;
      catTextOutput.focus(); catTextOutput.select();
      yakuCatSetStatus('全文を選択しました。Ctrl+Cでコピーできます。');
    });
    // 主の訳と、下に添えた訳を入れ替える。
    // 選んだ種類は覚える。毎回押し直すのは面倒なので。
    function yakuPreferredKind() {
      try { return window.localStorage.getItem('yaku-result-kind') || ''; } catch (e) { return ''; }
    }
    function yakuRememberKind(kind) {
      try { window.localStorage.setItem('yaku-result-kind', kind || ''); } catch (e) {}
    }
    function yakuSwapResult(button) {
      var card = document.querySelector('[data-yaku-main-card]');
      var main = card ? card.querySelector('[data-yaku-main-text]') : null;
      var kindEl = card ? card.querySelector('[data-yaku-main-kind]') : null;
      if (!main || !kindEl) return;
      var newText = yakuDecodeBase64Utf8(button.getAttribute('data-yaku-swap') || '');
      var newKind = button.getAttribute('data-yaku-swap-kind') || '';
      var oldText = main.textContent;
      var oldKind = kindEl.textContent;
      // 入れ替え。押した側には元の主が入るので、押し戻せる。
      main.textContent = newText;
      kindEl.textContent = newKind;
      button.setAttribute('data-yaku-swap', yakuEncodeUtf8Base64(oldText));
      button.setAttribute('data-yaku-swap-kind', oldKind);
      var head = button.querySelector('.result-alt-head');
      var body = button.querySelector('.result-alt-body');
      if (head) head.innerHTML = yakuEscape(oldKind) + '<span class="result-alt-chars">' + oldText.length + ' 字</span>';
      if (body) body.textContent = oldText.length > 90 ? (oldText.slice(0, 90) + '…') : oldText;
      var copy = card.querySelector('[data-yaku-copy], [data-yaku-copy-b64]');
      if (copy) { copy.removeAttribute('data-yaku-copy-b64'); copy.setAttribute('data-yaku-copy', newText); }
      yakuRememberKind(newKind);
    }
    function yakuEncodeUtf8Base64(s) {
      try { return window.btoa(String.fromCharCode.apply(null, new TextEncoder().encode(s))); }
      catch (e) { return ''; }
    }
    document.addEventListener('click', function (event) {
      var sw = event.target.closest && event.target.closest('[data-yaku-swap]');
      if (sw) { yakuSwapResult(sw); return; }
      // 短くする。押されたときだけ Copilot を呼ぶ。
      var shorten = event.target.closest && event.target.closest('[data-yaku-shorten]');
      if (shorten) { event.preventDefault(); yakuSubmitShorten(shorten); }
    });
    // 結果が出たら、前に選んだ種類を主に持ってくる。
    document.addEventListener('yaku:result-rendered', function () {
      var want = yakuPreferredKind();
      if (!want) return;
      var card = document.querySelector('[data-yaku-main-card]');
      var kindEl = card ? card.querySelector('[data-yaku-main-kind]') : null;
      if (!kindEl || kindEl.textContent === want) return;
      var alts = document.querySelectorAll('[data-yaku-swap]');
      for (var i = 0; i < alts.length; i++) {
        if (alts[i].getAttribute('data-yaku-swap-kind') === want) { yakuSwapResult(alts[i]); return; }
      }
    });    yakuCatLoadRecent();
    // 保存できていない行がある状態で閉じようとしたら止める。
    window.addEventListener('beforeunload', function (event) {
      if (!document.querySelector('.cat-unsaved, .cat-dirty') && !Object.keys(yakuCatSavePromises).length) return;
      event.preventDefault();
      event.returnValue = '';
    });
    // 既定の1ボタン。用語集で置換してから、残りを翻訳する。
    // 文例は入れない。往復が1回増えて重く、いつも要るものでもない。
    // 使いたい人は「段階ごとに実行する」から押せる。
    var catRun = document.getElementById('cat-run-button');
    if (catRun) catRun.addEventListener('click', function () {
      if (!yakuCatProjectId) { yakuCatSetStatus('先に原文を取り込んでください。'); return; }
      yakuCatWithOperation(catRun, function () { return yakuCatAfterFlush(function () {
        yakuCatSetStatus('用語集で置換しています…');
        return yakuCatPost('glossary', { id: yakuCatProjectId }).then(function (data) {
          yakuCatRender(data);
          return yakuCatTranslate('translate', true);
        }).catch(function (error) {
          yakuCatSetStatus('置換できませんでした: ' + (error && error.message ? error.message : ''));
        });
      }); });
    });
    var catGlossary = document.getElementById('cat-glossary-button');
    if (catGlossary) catGlossary.addEventListener('click', function () { yakuCatWithOperation(catGlossary, function () { return yakuCatGlossary(); }); });
    var catTranslate = document.getElementById('cat-translate-button');
    if (catTranslate) catTranslate.addEventListener('click', function () { yakuCatTranslate('translate'); });
    var catCorpus = document.getElementById('cat-corpus-button');
    if (catCorpus) catCorpus.addEventListener('click', function () { yakuCatTranslate('corpus'); });
    var catExport = document.getElementById('cat-export-button');
    if (catExport) catExport.addEventListener('click', function () { yakuCatWithOperation(catExport, function () { return yakuCatExport(); }); });
    // 絞り込みは手元の一覧を描き直すだけ。サーバーへは問い合わせない。
    document.addEventListener('change', function (event) {
      if (event.target && event.target.name === 'cat_filter') {
        yakuCatAfterFlush(function () { yakuCatRender(null); return Promise.resolve(true); });
      }
    });
    // 打鍵のたびに一覧を作り直すと、数百行では入力が引っかかる。
    // 手が止まってから描き直す。
    var catSearch = document.getElementById('cat-search');
    var catSearchTimer = null;
    if (catSearch) catSearch.addEventListener('input', function () {
      window.clearTimeout(catSearchTimer);
      catSearchTimer = window.setTimeout(function () {
        yakuCatAfterFlush(function () { yakuCatRender(null); return Promise.resolve(true); });
      }, 200);
    });
    // 取り込み元の切り替え。貼り付けが既定で、Excel は選んだときだけ出す。
    document.addEventListener('change', function (event) {
      if (!event.target || event.target.name !== 'cat_source') return;
      var mode = event.target.value;
      var textRow = document.getElementById('cat-text-row');
      var fileRow = document.getElementById('cat-file-row');
      var alignRow = document.getElementById('cat-align-row');
      var priorRow = document.getElementById('cat-prior-row');
      if (textRow) textRow.hidden = (mode !== 'text');
      if (fileRow) fileRow.hidden = (mode !== 'file');
      if (alignRow) alignRow.hidden = (mode !== 'align');
      if (priorRow) priorRow.hidden = (mode !== 'prior');
      var open = document.getElementById('cat-open-button');
      if (open) open.textContent = mode === 'align' ? '日英資料を取り込む' : (mode === 'prior' ? '前回と比べて始める' : (mode === 'file' ? 'Word・Excelを取り込む' : '確認を始める'));
      yakuSetButtonEnabled(yakuReady);
      yakuCatSetStatus(mode === 'text' ? '文章を貼り付けて「確認を始める」を押してください。'
        : mode === 'file' ? 'WordまたはExcelを選択して「Word・Excelを取り込む」を押してください。'
        : mode === 'prior' ? '前回の日英と今回の日本語を貼り付けて「前回と比べて始める」を押してください。'
        : '同じ資料の日本語版と英語版を貼り付けて「日英資料を取り込む」を押してください。');
    });
    var catFileInput = document.getElementById('cat-file-input');
    if (catFileInput) catFileInput.addEventListener('change', function () {
      yakuCatUploaded = null;
      var name = document.getElementById('cat-file-name');
      if (name) name.textContent = (catFileInput.files && catFileInput.files.length) ? catFileInput.files[0].name : 'ファイルを選択してください';
    });
    yakuBindFileDropTarget(document.getElementById('cat-drop'), catFileInput);
    // 触っただけの行を「手直し」にしない。以前は離れるたびに保存して
    // いたので、一覧を上から見ていくだけで全部が手直し扱いになっていた。
    // 「この行は見た」を記録する。訳文が変わっていなくても記録する。
    function yakuCatFocusAfterConfirm(index, data) {
      var allInputs = Array.prototype.slice.call(document.querySelectorAll('[data-yaku-cat-input]'));
      var next = null;
      for (var i = 0; i < allInputs.length; i++) {
        var candidateIndex = parseInt(allInputs[i].getAttribute('data-yaku-cat-input'), 10);
        var row = allInputs[i].closest('[data-yaku-cat-row]');
        if (candidateIndex > index && (!row || row.getAttribute('data-yaku-confirmed') !== '1')) { next = allInputs[i]; break; }
      }
      if (!next) {
        for (var j = 0; j < allInputs.length; j++) {
          var fallbackRow = allInputs[j].closest('[data-yaku-cat-row]');
          if (!fallbackRow || fallbackRow.getAttribute('data-yaku-confirmed') !== '1') { next = allInputs[j]; break; }
        }
      }
      if (next) {
        next.focus();
        try { next.setSelectionRange(next.value.length, next.value.length); } catch (e) {}
        next.scrollIntoView({ behavior: yakuScrollBehavior(), block: 'center' });
        return;
      }
      var exportButton = document.getElementById('cat-export-button');
      if (exportButton && !exportButton.disabled) {
        exportButton.focus();
        exportButton.scrollIntoView({ behavior: yakuScrollBehavior(), block: 'center' });
        return;
      }
      if ((Number(data && data.confirmed) || 0) < (Number(data && data.total) || 0)) {
        var search = document.getElementById('cat-search');
        if (search) {
          yakuCatSetStatus('検索条件の外に未確認の行があります。絞り込みを変更すると次の行を確認できます。');
          search.focus();
        }
      }
    }

    function yakuCatConfirm(index, editsFlushed) {
      if (!yakuCatProjectId || isNaN(index)) return Promise.resolve(null);
      if (yakuTranslating) { yakuCatSetStatus('処理中は確認できません。完了してからお試しください。'); return Promise.resolve(null); }
      if (!editsFlushed) return yakuCatAfterFlush(function () { return yakuCatConfirm(index, true); });
      var input = document.querySelector('[data-yaku-cat-input="' + index + '"]');
      return yakuCatCommit(input).then(function () {
        return yakuCatPost('confirm', { id: yakuCatProjectId, index: index, confirmed: true });
      }).then(function (data) {
        yakuCatRender(data);
        var reviewedSegment = (data.segments || []).filter(function (segment) { return Number(segment.index) === Number(index); })[0];
        if (data.review_blocked || (reviewedSegment && !reviewedSegment.confirmed)) {
          window.setTimeout(function () {
            var blockedInput = document.querySelector('[data-yaku-cat-input="' + index + '"]');
            if (blockedInput) {
              blockedInput.focus();
              blockedInput.scrollIntoView({ behavior: yakuScrollBehavior(), block: 'center' });
            }
          }, 0);
          return data;
        }
        if ((Number(data.confirmed) || 0) === (Number(data.total) || 0) && (Number(data.total) || 0) > 0) {
          yakuCatSetStatus(data.source === 'file'
            ? 'すべての行を確認しました。確認用DRAFT（外部配布不可）を作れます。'
            : 'すべての行を確認しました。確認済み訳文をコピーできます。');
        }
        window.setTimeout(function () { yakuCatFocusAfterConfirm(index, data); }, 0);
        return data;
      })
        .catch(function (error) {
          yakuCatSetStatus('確定できませんでした: ' + (error && error.message ? error.message : ''));
          var sameInput = document.querySelector('[data-yaku-cat-input="' + index + '"]');
          if (sameInput) {
            sameInput.setAttribute('aria-invalid', 'true');
            sameInput.focus();
          }
          return null;
        });
    }
    yakuCatCommit = function (input) {
      if (!input) return Promise.resolve(false);
      if (yakuTranslating) return Promise.resolve(false);
      var index = parseInt(input.getAttribute('data-yaku-cat-input'), 10);
      if (isNaN(index)) return Promise.resolve(false);
      var projectId = yakuCatProjectId;
      var saveKey = projectId + ':' + index;
      if (yakuCatSavePromises[saveKey]) {
        return yakuCatSavePromises[saveKey].then(function () { return yakuCatCommit(input); });
      }
      if (input.hasAttribute('data-yaku-original') && input.value === input.getAttribute('data-yaku-original')) {
        input.removeAttribute('data-yaku-dirty');
        var unchangedRow = input.closest('[data-yaku-cat-row]');
        if (unchangedRow) unchangedRow.classList.remove('cat-dirty');
        var unchangedExport = document.getElementById('cat-export-button');
        if (unchangedExport && yakuCatData) unchangedExport.disabled = !!yakuCatData.export_blocked;
        return Promise.resolve(false);
      }
      // 「元の値」を更新するのは保存が成功してから。先に更新すると、
      // 保存に失敗した行が「保存済み」と見なされて二度と送られない。
      var desired = input.value;
      var row = input.closest('[data-yaku-cat-row]');
      if (row) row.classList.add('cat-dirty');
      yakuCatSetSaveStatus('保存しています…', false);
      // revisionはproject全体で増えるため、別行の保存も必ず直列にする。
      // 2行を続けて離れたとき、同じrevisionで並行送信すると片方が競合する。
      var saveRequest = yakuCatSaveQueue.catch(function () { return false; }).then(function () {
        return yakuCatSaveSegment(projectId, index, desired);
      });
      yakuCatSaveQueue = saveRequest.catch(function () { return false; });
      var pending = saveRequest.then(function () {
        if (input.value === desired) {
          input.setAttribute('data-yaku-original', desired);
          input.removeAttribute('data-yaku-dirty');
          if (row) {
            row.classList.remove('cat-dirty');
            row.classList.remove('cat-unsaved');
          }
        } else {
          input.setAttribute('data-yaku-dirty', '1');
        }
        if (yakuCatProjectId === projectId && !yakuCatDirtyInputs().length) yakuCatSetSaveStatus('保存しました', false);
        return true;
      });
      yakuCatSavePromises[saveKey] = pending;
      return pending.then(function (changed) {
        delete yakuCatSavePromises[saveKey];
        return changed;
      }, function (error) {
        delete yakuCatSavePromises[saveKey];
        throw error;
      });
    };
    document.addEventListener('input', function (event) {
      var input = event.target.closest && event.target.closest('[data-yaku-cat-input]');
      if (input) yakuCatMarkDirty(input);
    });
    document.addEventListener('focusout', function (event) {
      var input = event.target.closest && event.target.closest('[data-yaku-cat-input]');
      if (input) yakuCatCommit(input).catch(function () {});
    });
    // いま見ている行を示す。市販の CAT エディタはどこも現在行を強調しており、
    // 長い一覧の中で自分の位置を見失わないようにしている。
    // 候補をマウスで押したときに、現在行の印が外れないようにする。
    // ボタンを押すとフォーカスが移るので focusin が先に走り、現在行の印が
    // 消えてから click が走る。すると差し込み先が見つからず、何も起きない。
    // 初めて使う人が最初に試す操作が黙って失敗していた（2026-08-08 に判明）。
    document.addEventListener('mousedown', function (event) {
      if (event.target.closest && event.target.closest('[data-yaku-cat-insert]')) {
        event.preventDefault();
      }
    });
    document.addEventListener('focusin', function (event) {
      var input = event.target.closest && event.target.closest('[data-yaku-cat-input]');
      var previous = document.querySelector('[data-yaku-cat-row].is-active');
      if (previous) previous.classList.remove('is-active');
      if (input) {
        var row = input.closest('[data-yaku-cat-row]');
        if (row) row.classList.add('is-active');
        yakuCatLoadCandidates(parseInt(input.getAttribute('data-yaku-cat-input'), 10));
      }
    });
    // Ctrl+1..9 で候補を差し込む。市販の CAT エディタと同じ割り当て。
    document.addEventListener('keydown', function (event) {
      if (!(event.ctrlKey || event.metaKey) || event.key < '1' || event.key > '9') return;
      var input = event.target.closest && event.target.closest('[data-yaku-cat-input]');
      if (!input) return;
      if (yakuTranslating || yakuCatOperationBusy) {
        event.preventDefault();
        yakuCatSetStatus('処理中は候補を挿入できません。完了してからお試しください。');
        return;
      }
      var buttons = document.querySelectorAll('#cat-candidates-list [data-yaku-cat-insert]');
      var pick = buttons[parseInt(event.key, 10) - 1];
      if (!pick) return;
      event.preventDefault();
      yakuCatInsert(input, pick.getAttribute('data-yaku-cat-insert'));
    });
    document.addEventListener('click', function (event) {
      var pick = event.target.closest && event.target.closest('[data-yaku-cat-insert]');
      if (!pick) return;
      if (yakuTranslating || yakuCatOperationBusy) {
        yakuCatSetStatus('処理中は候補を挿入できません。完了してからお試しください。');
        return;
      }
      var active = document.querySelector('[data-yaku-cat-row].is-active [data-yaku-cat-input]');
      if (active) yakuCatInsert(active, pick.getAttribute('data-yaku-cat-insert'));
    });
    // Ctrl+Enter で保存して次の訳文へ。市販の CAT エディタと同じ割り当てで、
    // 手をキーボードから離さずに一覧を下りていける。
    document.addEventListener('keydown', function (event) {
      if (event.key !== 'Enter' || !(event.ctrlKey || event.metaKey)) return;
      var input = event.target.closest && event.target.closest('[data-yaku-cat-input]');
      if (!input) return;
      event.preventDefault();
      if (yakuTranslating || yakuCatOperationBusy) {
        yakuCatSetStatus('処理中は確認できません。完了してからお試しください。');
        return;
      }
      // 直していなくても「確定」にする。機械訳を読んで「これで良い」と
      // 判断したことは、直したことと同じくらい記録に値する。記録が無いと
      // 翌日再開したときに「どこまで見たか」が分からない。
      var index = parseInt(input.getAttribute('data-yaku-cat-input'), 10);
      yakuCatWithOperation(null, function () { return yakuCatConfirm(index); }).then(function (confirmedData) {
        return confirmedData;
      }).catch(function () {});
    });
    // 簡易翻訳の結果から CAT へ渡す。原文をそのまま持っていくので、
    // 押した先に見慣れた文が並ぶ。覚えることは「1文ずつ見える」だけになる。
    document.addEventListener('click', function (event) {
      var toCat = event.target.closest && event.target.closest('[data-yaku-to-cat]');
      if (!toCat) return;
      var source = yakuDecodeBase64Utf8(toCat.getAttribute('data-yaku-to-cat'));
      // 訳文も一緒に受け取る。原文だけ渡していたので、渡した先で訳文の列が
      // 空になり、利用者から見れば「さっきの訳が消えた」うえに訳し直しを
      // 待たされていた。移行を促す導線が移行しない理由を作っていた。
      var translation = '';
      // 別案を上段へ入れ替えた場合は、生成時に属性へ入れた標準案ではなく、
      // 利用者がいま見ている訳案を渡す。「この訳案」の指す内容を一致させる。
      var visibleTranslation = document.querySelector('[data-yaku-main-text]');
      if (visibleTranslation) translation = visibleTranslation.textContent || '';
      if (!translation) {
        try { translation = yakuDecodeBase64Utf8(toCat.getAttribute('data-yaku-to-cat-translation') || ''); } catch (e) { translation = ''; }
      }
      var radio = document.querySelector('input[name="cat_source"][value="text"]');
      if (radio) { radio.checked = true; radio.dispatchEvent(new Event('change', { bubbles: true })); }
      var area = document.getElementById('cat-text');
      if (area) area.value = source;
      // 方向はサーバーが判定した実際の向きを使う。画面のラジオは「自動」の
      // ままのことが多く、それを見ていたので英→日の利用者が黙って
      // 日→英で取り込まれていた。
      var resolved = toCat.getAttribute('data-yaku-to-cat-direction');
      if (!resolved) {
        var dir = document.querySelector('input[name="text_direction"]:checked');
        if (dir && dir.value !== 'auto') resolved = dir.value;
      }
      if (resolved) {
        var catDir = document.querySelector('input[name="cat_direction"][value="' + resolved + '"]');
        if (catDir) catDir.checked = true;
      }
      yakuCatFocusFirstAfterRender = true;
      yakuActivateTab('cat');
      yakuCatWithOperation(toCat, function () { return yakuCatOpen(translation); });
    });
    document.addEventListener('click', function (event) {
      var merge = event.target.closest && event.target.closest('[data-yaku-cat-merge]');
      if (merge) {
        if (merge.getAttribute('data-yaku-cat-loss') === '1' && !window.confirm('結合すると、対象行の訳文が消えます。結合しますか？')) return;
        yakuCatWithOperation(merge, function () { return yakuCatRegroup('merge', parseInt(merge.getAttribute('data-yaku-cat-merge'), 10)); });
        return;
      }
      var split = event.target.closest && event.target.closest('[data-yaku-cat-split]');
      if (split) {
        if (split.getAttribute('data-yaku-cat-loss') === '1' && !window.confirm('解除すると、この行の訳文が消えます。解除しますか？')) return;
        yakuCatWithOperation(split, function () { return yakuCatRegroup('split', parseInt(split.getAttribute('data-yaku-cat-split'), 10)); });
      }
    });

    document.addEventListener('click', function (event) {
      var element = event.target.closest && event.target.closest('button');
      if (!element) return;
      if (element.matches('[data-yaku-open-workspace]')) {
        yakuCatWithOperation(element, function () { return yakuOpenWorkspace(element.getAttribute('data-yaku-open-workspace') || 'text'); });
        return;
      }
      if (element.matches('[data-yaku-main-entry]')) {
        yakuCatAfterFlush(function () {
          ++yakuCatViewRequest;
          yakuActivateTab('text');
          var mainInput = document.getElementById('input-text');
          if (mainInput) mainInput.focus();
        });
        return;
      }
      if (element.matches('.sheet-chip')) {
        element.classList.toggle('is-selected');
        element.setAttribute('aria-pressed', element.classList.contains('is-selected') ? 'true' : 'false');
        var selected = Array.prototype.map.call(document.querySelectorAll('.sheet-chip.is-selected'), function (chip) { return chip.getAttribute('data-yaku-sheet'); });
        var sheetInput = document.getElementById('file-sheets');
        yakuSheetSelection = selected.filter(Boolean);
        if (sheetInput) sheetInput.value = yakuSheetSelection.join(', ');
        yakuUpdateFileButton();
        return;
      }
      if (element.matches('.copy-button')) { yakuCopy(element); return; }
      if (element.matches('.cancel-button')) {
        var cancelId = element.getAttribute('data-yaku-job-id') || yakuActiveJobId;
        if (!cancelId) return;
        element.disabled = true;
        element.textContent = 'キャンセル中';
        yakuJsonPost('/api/cancel-translation', { job_id: cancelId }).then(yakuResponseJson).then(function (data) {
          yakuUpdateJobCard(data);
          if (yakuTerminalMode(data.mode)) yakuFinishJob(data);
          else {
            yakuActiveJobId = cancelId;
            window.clearTimeout(yakuJobTimer);
            yakuJobTimer = window.setTimeout(yakuPollJobStatus, 300);
          }
        }).catch(function () {
          element.disabled = false;
          element.textContent = 'キャンセル';
        });
        return;
      }
      if (element.matches('[data-yaku-download-job]')) { yakuDownload(element.getAttribute('data-yaku-download-job'), element); return; }
      if (element.matches('.open-output-button')) {
        element.disabled = true;
        yakuJsonPost('/api/open-output', { job_id: element.getAttribute('data-yaku-job-id') || '' }).then(yakuResponseText).then(function (html) {
          var holder = element.closest('.file-result-card') || element.parentNode;
          var note = document.createElement('div');
          note.innerHTML = html;
          holder.appendChild(note);
        }).finally(function () { element.disabled = false; });
        return;
      }
    });

    Array.prototype.forEach.call(document.querySelectorAll('details[id]'), function (details) {
      yakuDetailsOpen[details.id] = details.open;
      details.addEventListener('toggle', function () { yakuDetailsOpen[details.id] = details.open; });
    });
    document.body.addEventListener('htmx:afterSwap', function () {
      Object.keys(yakuDetailsOpen).forEach(function (id) {
        var details = document.getElementById(id);
        if (details) details.open = !!yakuDetailsOpen[id];
      });
    });
  }

  function yakuStart() {
    sessionToken = yakuMeta('yaku-session');
    fileMaxBytes = Number(yakuMeta('yaku-file-max-bytes')) || fileMaxBytes;
    if (!sessionToken || sessionToken.indexOf('__YAKU_') === 0) {
      document.body.innerHTML = '<main class="shell"><div class="alert alert-error">セッションを初期化できませんでした。YakuLingoを再起動してください。</div></main>';
      return;
    }
    var savedTextSize = 'standard';
    try { savedTextSize = window.localStorage.getItem('yaku-text-size') || 'standard'; } catch (e) {}
    yakuApplyTextSize(savedTextSize === 'large');
    yakuBindEvents();
    yakuUpdateInputMeta();
    var shortcut = document.getElementById('shortcut-mod');
    if (shortcut) shortcut.textContent = /Mac|iPhone|iPad|iPod/.test(navigator.platform || '') ? '⌘' : 'Ctrl';
    yakuResetFileInfoMessage();
    yakuRestoreTabJob();
    yakuPollReadyState();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', yakuStart);
  else yakuStart();
}());
