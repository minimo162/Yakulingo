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
  var yakuPrivacyStatus = null;
  var yakuSheetSelection = null;
  var yakuFileDirectionTouched = false;
  var yakuDetailsOpen = {};
  var yakuSettingsSaving = false;
  var yakuActiveTab = 'text';
  var yakuActiveJobKind = 'text';
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
    return '<div class="empty-state">このタブの翻訳結果はまだありません</div>';
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
      if (!response.ok) {
        var error = new Error(data.error || data.detail || ('HTTP ' + response.status));
        error.status = response.status;
        error.code = data.error_code || '';
        throw error;
      }
      return data;
    });
  }

  function yakuResponseText(response) {
    return response.text().then(function (text) {
      if (!response.ok) throw new Error(text || ('HTTP ' + response.status));
      return text;
    });
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
      button.textContent = yakuTranslating ? '翻訳中' : (enabled ? '翻訳' : '準備中');
    }
    // CAT の Copilot を使うボタンも同じ扱いにする。無効化していなかったので、
    // CAT から始めた人が押しても画面が完全に無反応になっていた。
    // 主役にしたい画面の入口で、押しても何も起きないのは致命的である。
    var catActive = !!enabled && !yakuTranslating;
    [['cat-translate-button', '残りをCopilotで翻訳'], ['cat-corpus-button', '文例を検索']].forEach(function (pair) {
      var b = document.getElementById(pair[0]);
      if (!b) return;
      b.disabled = !catActive;
      b.setAttribute('aria-disabled', catActive ? 'false' : 'true');
      b.textContent = yakuTranslating ? '実行中' : (enabled ? pair[1] : '準備中');
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
    if (data) yakuSetStatus(data.label, data.class);
    yakuSetButtonEnabled(yakuReady);
    yakuSetStartupMessage(data);
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
      else if (selected !== 'auto') direction.textContent = (selected === 'to_en' ? '日→英' : '英他→日') + '（手動）';
      else direction.textContent = analysis.dir === 'to_en' ? '日→英' : '英他→日';
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
      yakuTranslating = false;
      yakuActiveJobId = null;
      var catTarget = yakuGetResultTarget();
      if (catTarget) { catTarget.removeAttribute('aria-busy'); catTarget.innerHTML = '<div class="empty-state">実行中ジョブと翻訳結果はここに表示されます</div>'; }
      yakuSetButtonEnabled(yakuReady);
      yakuPollReadyState();
      // 突き合わせは訳文ではなく対応を返す。組み立てが違うので分ける。
      if (yakuCatAligning) { yakuCatAligning = false; yakuCatAlignApply(catJobId); }
      else { yakuCatApply(catJobId); }
      return;
    }
    var result = yakuGetResultTarget();
    var completedKind = yakuActiveJobKind === 'file' ? 'file' : 'text';
    var completedHtml = data && data.html ? data.html : '<div class="alert alert-warning">翻訳結果を取得できませんでした。</div>';
    yakuResultByTab[completedKind] = completedHtml;
    yakuTranslating = false;
    yakuActiveJobId = null;
    yakuActivateTab(completedKind);
    if (result) {
      result.removeAttribute('aria-busy');
      result.innerHTML = completedHtml;
      window.setTimeout(function () { yakuScrollCompletionIntoView(result); }, 0);
    }
    yakuSetButtonEnabled(yakuReady);
    yakuPollReadyState();
    if (window.htmx) window.htmx.trigger(document.body, 'yaku-history-refresh');
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
    var normalizedKind = (kind === 'file' || kind === 'cat') ? kind : 'text';
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
    yakuActivateTab(kind === 'file' ? 'file' : 'text');
    yakuRenderJobLoading(jobId, 0, 'このタブのジョブを復元しています', '結果確認中');
    yakuStartJobPolling(jobId, kind);
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
      var errorHtml = '<div class="alert alert-error">' + yakuEscape(error && error.message ? error.message : fallback) + '</div>';
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
    if (!yakuConfirmUnsavedSettings()) return;
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

  // ---------------------------------------------------------------- CAT
  // ファイル翻訳と同じことを、押した分だけ進める。
  // 取り込む → 用語集で置換 → 残りをCopilotで訳す → 出力。
  var yakuCatProjectId = '';
  // 走っているジョブが「突き合わせ」かどうか。終わったあとの組み立てが
  // 訳文の取り込みとは違うので、ここで区別する。
  var yakuCatAligning = false;
  var yakuCatUploaded = null;

  function yakuCatSetStatus(text) {
    var el = document.getElementById('cat-status');
    if (el) el.textContent = text;
  }

  function yakuCatOriginLabel(origin) {
    if (origin === 'glossary') return '用語集';
    if (origin === 'copilot') return 'Copilot';
    if (origin === 'manual') return '手直し';
    return '';
  }

  // 最後に描いた一覧。絞り込みのたびにサーバーへ問い合わせない。
  var yakuCatData = null;

  function yakuCatFilterValue() {
    var checked = document.querySelector('input[name="cat_filter"]:checked');
    return checked ? checked.value : 'all';
  }

  function yakuCatKeep(s, mode, needle) {
    if (mode === 'untranslated' && (s.translation || '').trim()) return false;
    // 途中から再開するときに一番使う。まだ見ていない行だけを出す。
    if (mode === 'unconfirmed' && s.confirmed) return false;
    if (mode === 'joined' && !s.joined) return false;
    if (mode === 'manual' && s.origin !== 'manual') return false;
    if (needle) {
      var hay = ((s.source || '') + '\n' + (s.translation || '')).toLowerCase();
      if (hay.indexOf(needle) < 0) return false;
    }
    return true;
  }

  function yakuCatRender(data) {
    if (data) yakuCatData = data;
    data = yakuCatData;
    if (!data) return;
    yakuCatProjectId = data.id || '';
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
      else loc = (s.kind === 'shape') ? '図形' : (s.kind === 'chart' ? 'グラフ' : s.kind);
      var origin = yakuCatOriginLabel(s.origin);
      // 繋ぎ直しの操作。自動で完璧に分けるのは無理なので、外れたら人が直す。
      var ops = '';
      if (s.can_merge) ops += '<button type="button" class="cat-op" data-yaku-cat-merge="' + s.index + '" title="次の行と結合します（訳文は消えます）">↓結合</button>';
      if (s.can_split) ops += '<button type="button" class="cat-op" data-yaku-cat-split="' + s.index + '" title="セル1つずつに戻します（訳文は消えます）">解除</button>';
      // 行の状態を色で示す。市販の CAT エディタは状態列を色で分けており、
      // 一覧を眺めたときに「どこが手つかずか」が一目で分かる。
      var state = (s.translation || '').trim() ? (s.origin || 'other') : 'untranslated';
      rows.push(
        '<tr data-yaku-cat-row="' + s.index + '" data-yaku-cat-state="' + yakuEscape(state) + '"' +
        ' data-yaku-confirmed="' + (s.confirmed ? '1' : '0') + '">' +
        '<td class="cat-col-no">' + (s.index + 1) + (s.confirmed ? '<span class="cat-confirmed" title="確認済み">✓</span>' : '') + '</td>' +
        '<td class="cat-col-loc"><span class="cat-loc" title="' + yakuEscape(s.location || '') + '">' + yakuEscape(loc) + '</span>' +
        (origin ? '<span class="cat-origin cat-origin-' + yakuEscape(s.origin) + '">' + yakuEscape(origin) + '</span>' : '') +
        (ops ? '<span class="cat-ops">' + ops + '</span>' : '') + '</td>' +
        '<td class="cat-source">' + yakuEscape(s.source) + '</td>' +
        '<td class="cat-target"><textarea rows="2" data-yaku-cat-input="' + s.index + '" data-yaku-original="' + yakuEscape(s.translation || '') + '">' + yakuEscape(s.translation || '') + '</textarea></td>' +
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
    if (translateBtn) translateBtn.textContent = data.corpus_ready ? '文例を使って残りを翻訳' : '残りをCopilotで翻訳';
    // 貼り付けたテキストは書き戻す元が無い。出口が違うので言葉も変える。
    var exportBtn = document.getElementById('cat-export-button');
    if (exportBtn) exportBtn.textContent = (data.source === 'text') ? '訳文をコピー' : '出力';
    // 突き合わせたときだけ「文例として保存」を出す。
    var saveBtn = document.getElementById('cat-save-corpus-button');
    if (saveBtn) saveBtn.hidden = (data.source !== 'align');
    yakuCatSetStatus(data.file_name + ' … ' + data.total + ' 行（訳あり ' + data.translated + ' / 残り ' + data.remaining + '、結合 ' + data.joined + '）');
    yakuCatUpdateProgress(data);
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
    if (text) text.textContent = '確認 ' + pct + '%（' + confirmed + ' / ' + total + '）　訳あり ' + filled;
  }

  function yakuCatPost(action, payload) {
    return yakuJsonPost('/api/cat/' + action, payload).then(function (response) {
      return response.text().then(function (text) {
        var data = null;
        try { data = JSON.parse(text); } catch (e) { data = null; }
        if (!response.ok) throw new Error((data && data.error) ? data.error : text);
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

  // 前回の続きを出す。閉じても再起動しても戻せることを、目に見える形にする。
  function yakuCatLoadRecent() {
    yakuCatPost('recent', {}).then(function (data) {
      var box = document.getElementById('cat-resume');
      var list = document.getElementById('cat-resume-list');
      if (!box || !list) return;
      var items = (data.projects || []).filter(function (p) { return p.total > 0; });
      if (!items.length) { box.hidden = true; return; }
      box.hidden = false;
      list.innerHTML = items.slice(0, 3).map(function (p) {
        var pct = p.total ? Math.round((p.confirmed / p.total) * 100) : 0;
        return '<button type="button" class="cat-op" data-yaku-cat-resume="' + yakuEscape(p.id) + '">' +
          yakuEscape(p.file_name) + '（確認 ' + pct + '%）</button>';
      }).join(' ');
    }).catch(function () {});
  }

  function yakuCatResume(id) {
    yakuCatSetStatus('前回の作業を読み込んでいます…');
    yakuCatPost('resume', { project_id: id }).then(yakuCatRender).catch(function (error) {
      yakuCatSetStatus('前回の作業を読み込めませんでした: ' + (error && error.message ? error.message : ''));
    });
  }

  function yakuCatOpen(existingTranslation) {
    var checked = document.querySelector('input[name="cat_direction"]:checked');
    yakuCatSetStatus('取り込んでいます…');
    yakuCatSource().then(function (source) {
      source.direction = checked ? checked.value : 'to_en';
      var kind = document.querySelector('input[name="cat_kind"]:checked');
      source.kind = kind ? kind.value : 'internal';
      // 簡易翻訳から渡された訳文があれば一緒に送る。
      // 開いた瞬間に原文と訳文が並ぶので、押すボタンがゼロで確認に入れる。
      if (existingTranslation) { source.translation = existingTranslation; }
      return yakuCatPost('open', source);
    }).then(yakuCatRender).catch(function (error) {
      yakuCatSetStatus('取り込めませんでした: ' + (error && error.message ? error.message : ''));
    });
  }

  function yakuCatGlossary() {
    if (!yakuCatProjectId) return;
    yakuCatSetStatus('用語集で置換しています…');
    yakuCatPost('glossary', { id: yakuCatProjectId }).then(yakuCatRender).catch(function (error) {
      yakuCatSetStatus('置換できませんでした: ' + (error && error.message ? error.message : ''));
    });
  }

  function yakuCatTranslate(mode) {
    if (!yakuCatProjectId) {
      yakuCatSetStatus('先に原文を取り込んでください。');
      return;
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
    yakuTranslating = true;
    yakuActiveJobKind = 'cat';
    yakuSetButtonEnabled(false);
    yakuRenderJobLoading('', 0, mode === 'corpus' ? '文例を検索中' : 'Copilotで翻訳中', '準備中');
    yakuScrollJobResultIntoView();
    // ジョブは別のランスペースで走り、メモリ上のプロジェクトを触れない。
    // 結果だけを返させ、完了後に apply で取り込む。
    yakuJsonPost('/api/cat/translate', { id: yakuCatProjectId, mode: mode || 'translate' }).then(yakuResponseText).then(yakuStartFromHtml).catch(function (error) {
      yakuShowStartError(error, mode === 'corpus' ? '文例を検索できませんでした。' : 'Copilot翻訳を開始できませんでした。');
    });
  }

  function yakuCatApply(jobId) {
    if (!yakuCatProjectId || !jobId) return;
    yakuCatSetStatus('訳文を取り込んでいます…');
    yakuCatPost('apply', { id: yakuCatProjectId, job_id: jobId }).then(yakuCatRender).catch(function (error) {
      yakuCatSetStatus('訳文を取り込めませんでした: ' + (error && error.message ? error.message : ''));
    });
  }

  // 既にある訳と突き合わせる。数分かかるのでジョブで走らせ、
  // 終わったら対を受け取ってグリッドを組み立てる。
  function yakuCatAlign() {
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
    yakuJsonPost('/api/cat/align', {
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
    var name = document.getElementById('cat-align-name');
    var dir = document.querySelector('input[name="cat_direction"]:checked');
    yakuCatSetStatus('対応を取り込んでいます…');
    yakuCatPost('align-apply', {
      job_id: jobId,
      direction: dir ? dir.value : 'to_en',
      file_name: name ? name.value : ''
    }).then(yakuCatRender).catch(function (error) {
      yakuCatSetStatus('対応を取り込めませんでした: ' + (error && error.message ? error.message : ''));
    });
  }

  // 確かめた対訳を文例として貯める。押すまで貯まらない。
  function yakuCatSaveCorpus() {
    if (!yakuCatProjectId) return;
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

  function yakuCatExport() {
    if (!yakuCatProjectId) return;
    yakuCatSetStatus('出力しています…');
    yakuCatPost('export', { id: yakuCatProjectId }).then(function (data) {
      // 貼り付けたテキストは書き戻す元が無いので、繋いだ訳文をクリップボードへ。
      // 簡易翻訳と同じ終わり方にして、覚えることを増やさない。
      if (data.text) {
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(data.text).then(function () {
            yakuCatSetStatus('訳文をコピーしました（' + data.written + '件）。');
          }, function () {
            yakuCatSetStatus('訳文はできましたが、コピーできませんでした。訳文欄から選んでコピーしてください。');
          });
        } else {
          yakuCatSetStatus('訳文はできましたが、コピーできませんでした。訳文欄から選んでコピーしてください。');
        }
        return;
      }
      yakuCatSetStatus('出力しました: ' + data.output_path);
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
        return '<button type="button" class="cat-cand" data-yaku-cat-insert="' + yakuEscape(c.target) + '">' +
          '<span class="cat-cand-no">' + (i + 1) + '</span>' +
          '<span class="cat-cand-tag' + (c.exact ? ' is-exact' : '') + '">' + tag + '</span>' +
          '<span class="cat-cand-src">' + yakuEscape(c.source) + '</span>' +
          '<span class="cat-cand-tgt">' + yakuEscape(c.target) + '</span>' +
          '</button>';
      }).join('');
    }).catch(function () {});
  }

  function yakuCatInsert(input, text) {
    if (!input || !text) return;
    // 空なら丸ごと入れる。書きかけならカーソル位置へ差し込む。
    if (!input.value.trim()) { input.value = text; }
    else {
      var at = (typeof input.selectionStart === 'number') ? input.selectionStart : input.value.length;
      input.value = input.value.slice(0, at) + text + input.value.slice(at);
      input.selectionStart = input.selectionEnd = at + text.length;
    }
    input.focus();
  }

  function yakuCatRegroup(action, index) {
    if (!yakuCatProjectId) return;
    yakuCatSetStatus(action === 'merge' ? '結合しています…' : '解除しています…');
    yakuCatPost(action, { id: yakuCatProjectId, index: index }).then(yakuCatRender).catch(function (error) {
      yakuCatSetStatus('変更できませんでした: ' + (error && error.message ? error.message : ''));
    });
  }

  function yakuCatSaveSegment(index, text) {
    if (!yakuCatProjectId) return;
    yakuCatPost('segment', { id: yakuCatProjectId, index: index, text: text }).then(function (data) {
      // 全体を描き直すと編集中のカーソルが飛ぶので、その行と件数だけ更新する。
      yakuCatData = data;
      yakuCatSetStatus(data.file_name + ' … ' + data.total + ' 行（訳あり ' + data.translated + ' / 残り ' + data.remaining + '、結合 ' + data.joined + '）');
      yakuCatUpdateProgress(data);
      var tr = document.querySelector('[data-yaku-cat-row="' + index + '"]');
      if (tr) {
        tr.setAttribute('data-yaku-cat-state', text.trim() ? 'manual' : 'untranslated');
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
        tr.setAttribute('data-yaku-confirmed', '1');
        tr.classList.remove('cat-unsaved');
      }
    }).catch(function (error) {
      // 黙って捨てない。捨てると、その行は「保存済み」と見なされて
      // 二度と送られない。直した内容が消えたことに誰も気づけない。
      var tr = document.querySelector('[data-yaku-cat-row="' + index + '"]');
      if (tr) tr.classList.add('cat-unsaved');
      var input = document.querySelector('[data-yaku-cat-input="' + index + '"]');
      // 保存できていないので「元の値」を戻す。次の機会に送り直せるようにする。
      if (input) input.removeAttribute('data-yaku-original');
      yakuCatSetStatus((index + 1) + '行目を保存できませんでした: ' + (error && error.message ? error.message : '') + '（この行は赤く表示しています）');
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
      var detected = data.DetectedDirection === 'to_en' ? '日→英' : (data.DetectedDirection === 'to_jp' ? '英他→日' : '-');
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

  function yakuSubmitFileTranslation(event) {
    event.preventDefault();
    if (!yakuReady || yakuTranslating || !yakuHasFileSource()) { yakuPollReadyState(); return; }
    if (yakuHasExplicitEmptySheetSelection()) { yakuUpdateFileButton(); return; }
    if (!yakuConfirmUnsavedSettings()) return;
    yakuTranslating = true;
    yakuActiveJobKind = 'file';
    yakuSetButtonEnabled(false);
    yakuRenderJobLoading('', 0, 'ファイル翻訳ジョブを開始中', '抽出準備中');
    yakuScrollJobResultIntoView();
    yakuBuildFilePayload().then(function (payload) {
      return yakuJsonPost('/api/translate-file', payload).then(yakuResponseText);
    }).then(function (html) {
      yakuUploadedFile = null;
      yakuStartFromHtml(html);
    }).catch(function (error) {
      yakuUploadedFile = null;
      yakuShowStartError(error, 'ファイル翻訳を開始できませんでした。');
    });
  }

  function yakuActivateTab(name, focus) {
    var target = (name === 'file' || name === 'cat') ? name : 'text';
    yakuActiveTab = target;
    document.querySelectorAll('[data-yaku-tab]').forEach(function (button) {
      var active = button.getAttribute('data-yaku-tab') === target;
      button.classList.toggle('is-active', active);
      button.classList.toggle('active', active);
      button.setAttribute('aria-selected', active ? 'true' : 'false');
      button.setAttribute('tabindex', active ? '0' : '-1');
      if (active && focus) button.focus();
    });
    document.querySelectorAll('[data-yaku-panel]').forEach(function (panel) {
      var active = panel.getAttribute('data-yaku-panel') === target;
      panel.hidden = !active;
      panel.classList.toggle('is-active', active);
      panel.classList.toggle('active', active);
    });
    if (!yakuTranslating) {
      var result = yakuGetResultTarget();
      if (result) result.innerHTML = yakuResultByTab[target] || yakuEmptyResultHtml();
    }
  }

  function yakuFormDataToObject(form) {
    var data = {};
    Array.prototype.forEach.call(form.elements, function (element) {
      if (!element.name || element.disabled || ['submit', 'button'].indexOf(element.type) >= 0) return;
      if (element.type === 'checkbox') {
        data[element.name] = !!element.checked;
        return;
      }
      if (element.type === 'radio') {
        if (!element.checked) return;
      }
      data[element.name] = element.value;
    });
    return data;
  }

  function yakuSettingsForm() {
    return document.querySelector('form[data-yaku-settings-form]');
  }

  function yakuUpdateSettingsState(form, mode, level) {
    if (!form) return;
    var state = form.querySelector('[data-yaku-settings-state]');
    if (!state) return;
    state.classList.remove('is-enabled', 'is-disabled', 'is-dirty');
    if (mode === 'dirty') {
      state.classList.add('is-dirty');
      state.textContent = '未保存の変更があります。保存するまで翻訳には反映されません。';
      return;
    }
    var normalized = ['minimal', 'standard', 'full'].indexOf(level) >= 0 ? level : 'standard';
    state.classList.add(normalized === 'full' ? 'is-enabled' : 'is-disabled');
    state.textContent = 'ログ診断レベル：' + normalized + '（保存済み）';
  }

  function yakuMarkSettingsDirty(form) {
    if (!form) return;
    form.setAttribute('data-yaku-dirty', 'true');
    yakuUpdateSettingsState(form, 'dirty', false);
  }

  function yakuConfirmUnsavedSettings() {
    if (yakuSettingsSaving) {
      window.alert('設定を保存中です。「設定を保存しました」と表示されてから翻訳してください。');
      return false;
    }
    var form = yakuSettingsForm();
    if (!form || form.getAttribute('data-yaku-dirty') !== 'true') return true;
    return window.confirm('設定に未保存の変更があります。\nこのまま翻訳すると、現在保存済みの設定を使用します。\n保存せずに続行しますか？');
  }

  function yakuSubmitJsonForm(form) {
    var selector = form.getAttribute('data-yaku-target') || '';
    var target = selector ? document.querySelector(selector) : null;
    var button = form.querySelector('[type="submit"]');
    var isSettingsForm = form.matches('[data-yaku-settings-form]');
    if (isSettingsForm) yakuSettingsSaving = true;
    if (button) button.disabled = true;
    var payload = yakuFormDataToObject(form);
    yakuJsonPost(form.getAttribute('data-yaku-json-post'), payload).then(yakuResponseText).then(function (html) {
      if (target) target.innerHTML = html;
      if (isSettingsForm) {
        var saved = target && target.querySelector('[data-yaku-settings-saved="true"]');
        if (saved) {
          var level = saved.getAttribute('data-yaku-diagnostics-level') || 'standard';
          form.setAttribute('data-yaku-dirty', 'false');
          form.setAttribute('data-yaku-saved-diagnostics', level);
          yakuUpdateSettingsState(form, 'saved', level);
        }
      }
    }).catch(function (error) {
      if (target) target.innerHTML = '<div class="alert alert-error">' + yakuEscape(error.message) + '</div>';
    }).finally(function () {
      if (isSettingsForm) yakuSettingsSaving = false;
      if (button) button.disabled = false;
    });
  }

  function yakuLoadPrivacyStatus() {
    var target = document.getElementById('privacy-result');
    return yakuFetch('/api/privacy-status').then(yakuResponseJson).then(function (data) {
      yakuPrivacyStatus = data;
      if (target) {
        target.innerHTML = '<div class="muted">履歴メタデータ ' + yakuEscape(String(data.history_count || 0)) + '件（' + yakuEscape(data.history_path || '-') + '）／全文診断 ' + yakuEscape(String(data.diagnostic_count || 0)) + '件（' + yakuEscape(data.diagnostic_path || '-') + '）</div>';
      }
      return data;
    }).catch(function () { return null; });
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

  function yakuBindEvents() {
    var textForm = document.getElementById('text-form');
    var inputText = document.getElementById('input-text');
    var fileInput = document.getElementById('file-input');
    var filePath = document.getElementById('file-path');
    var fileSheets = document.getElementById('file-sheets');
    var fileForm = document.getElementById('file-form');
    var fileInfoButton = document.getElementById('file-info-button');
    var fileDrop = document.getElementById('file-drop');
    var fileClearButton = document.getElementById('file-clear-button');

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
    if (fileForm) fileForm.addEventListener('submit', yakuSubmitFileTranslation);
    if (fileDrop) {
      fileDrop.addEventListener('keydown', function (event) {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          if (fileInput) fileInput.click();
        }
      });
      ['dragenter', 'dragover'].forEach(function (name) {
        fileDrop.addEventListener(name, function (event) { event.preventDefault(); fileDrop.classList.add('dragover'); });
      });
      ['dragleave', 'drop'].forEach(function (name) {
        fileDrop.addEventListener(name, function (event) { event.preventDefault(); fileDrop.classList.remove('dragover'); });
      });
      fileDrop.addEventListener('drop', function (event) {
        if (fileInput && event.dataTransfer && event.dataTransfer.files.length) {
          fileInput.files = event.dataTransfer.files;
          fileInput.dispatchEvent(new Event('change'));
        }
      });
    }

    document.addEventListener('submit', function (event) {
      var revise = event.target.closest && event.target.closest('form[data-yaku-revise]');
      if (revise) { event.preventDefault(); yakuSubmitRevision(revise); return; }
      var form = event.target.closest && event.target.closest('form[data-yaku-json-post]');
      if (!form) return;
      event.preventDefault();
      yakuSubmitJsonForm(form);
    });

    document.addEventListener('input', function (event) {
      var form = event.target.closest && event.target.closest('form[data-yaku-settings-form]');
      if (form) yakuMarkSettingsDirty(form);
    });

    // CAT の操作。訳文欄は離れたときに保存する。打つたびに送ると往復が増える。
    var catOpen = document.getElementById('cat-open-button');
    if (catOpen) catOpen.addEventListener('click', function () { if (yakuCatSourceMode() === 'align') yakuCatAlign(); else yakuCatOpen(); });
    var catSaveCorpus = document.getElementById('cat-save-corpus-button');
    if (catSaveCorpus) catSaveCorpus.addEventListener('click', yakuCatSaveCorpus);
    document.addEventListener('click', function (event) {
      var resume = event.target.closest && event.target.closest('[data-yaku-cat-resume]');
      if (resume) yakuCatResume(resume.getAttribute('data-yaku-cat-resume'));
    });
    // 文書の種類を選んだときに、何が変わるかを一言で出す。
    // 単位の書き方まで変わるので、選び間違いに気づける場所が要る。
    function yakuCatKindNote() {
      var kind = document.querySelector('input[name="cat_kind"]:checked');
      var note = document.getElementById('cat-kind-note');
      if (!note) return;
      note.textContent = (kind && kind.value === 'public')
        ? '公表資料：公表訳の言い回しに従います。単位は ¥12.2 billion。公表後は文例として保存できます。'
        : '内部資料：スペースに収まることを優先します。単位は oku、略記あり。文例には保存しません。';
    }
    document.addEventListener('change', function (event) {
      if (event.target && event.target.name === 'cat_kind') yakuCatKindNote();
    });
    yakuCatKindNote();
    yakuCatLoadRecent();
    // 保存できていない行がある状態で閉じようとしたら止める。
    window.addEventListener('beforeunload', function (event) {
      if (!document.querySelector('.cat-unsaved')) return;
      event.preventDefault();
      event.returnValue = '';
    });
    // 既定の1ボタン。用語集で置換してから、残りを翻訳する。
    // 文例は入れない。往復が1回増えて重く、いつも要るものでもない。
    // 使いたい人は「段階ごとに実行する」から押せる。
    var catRun = document.getElementById('cat-run-button');
    if (catRun) catRun.addEventListener('click', function () {
      if (!yakuCatProjectId) { yakuCatSetStatus('先に原文を取り込んでください。'); return; }
      yakuCatSetStatus('用語集で置換しています…');
      yakuCatPost('glossary', { id: yakuCatProjectId }).then(function (data) {
        yakuCatRender(data);
        yakuCatTranslate('translate');
      }).catch(function (error) {
        yakuCatSetStatus('置換できませんでした: ' + (error && error.message ? error.message : ''));
      });
    });
    var catGlossary = document.getElementById('cat-glossary-button');
    if (catGlossary) catGlossary.addEventListener('click', yakuCatGlossary);
    var catTranslate = document.getElementById('cat-translate-button');
    if (catTranslate) catTranslate.addEventListener('click', function () { yakuCatTranslate('translate'); });
    var catCorpus = document.getElementById('cat-corpus-button');
    if (catCorpus) catCorpus.addEventListener('click', function () { yakuCatTranslate('corpus'); });
    var catExport = document.getElementById('cat-export-button');
    if (catExport) catExport.addEventListener('click', yakuCatExport);
    // 絞り込みは手元の一覧を描き直すだけ。サーバーへは問い合わせない。
    document.addEventListener('change', function (event) {
      if (event.target && event.target.name === 'cat_filter') yakuCatRender(null);
    });
    // 打鍵のたびに一覧を作り直すと、数百行では入力が引っかかる。
    // 手が止まってから描き直す。
    var catSearch = document.getElementById('cat-search');
    var catSearchTimer = null;
    if (catSearch) catSearch.addEventListener('input', function () {
      window.clearTimeout(catSearchTimer);
      catSearchTimer = window.setTimeout(function () { yakuCatRender(null); }, 200);
    });
    // 取り込み元の切り替え。貼り付けが既定で、Excel は選んだときだけ出す。
    document.addEventListener('change', function (event) {
      if (!event.target || event.target.name !== 'cat_source') return;
      var mode = event.target.value;
      var textRow = document.getElementById('cat-text-row');
      var fileRow = document.getElementById('cat-file-row');
      var alignRow = document.getElementById('cat-align-row');
      if (textRow) textRow.hidden = (mode !== 'text');
      if (fileRow) fileRow.hidden = (mode !== 'file');
      if (alignRow) alignRow.hidden = (mode !== 'align');
      var open = document.getElementById('cat-open-button');
      if (open) open.textContent = (mode === 'align') ? '突き合わせる' : '取り込む';
      yakuCatSetStatus(mode === 'text' ? 'テキストを貼り付けて「取り込む」を押してください。'
        : mode === 'file' ? 'Excelを選択して「取り込む」を押してください。'
        : '同じ資料の日本語版と英語版を貼り付けて「突き合わせる」を押してください。');
    });
    var catFileInput = document.getElementById('cat-file-input');
    if (catFileInput) catFileInput.addEventListener('change', function () {
      yakuCatUploaded = null;
      var name = document.getElementById('cat-file-name');
      if (name) name.textContent = (catFileInput.files && catFileInput.files.length) ? catFileInput.files[0].name : 'ローカルパス指定も利用できます';
    });
    // 触っただけの行を「手直し」にしない。以前は離れるたびに保存して
    // いたので、一覧を上から見ていくだけで全部が手直し扱いになっていた。
    // 「この行は見た」を記録する。訳文が変わっていなくても記録する。
    function yakuCatConfirm(index) {
      if (!yakuCatProjectId || isNaN(index)) return;
      yakuCatPost('confirm', { id: yakuCatProjectId, index: index, confirmed: true })
        .then(yakuCatRender)
        .catch(function (error) {
          yakuCatSetStatus('確定できませんでした: ' + (error && error.message ? error.message : ''));
        });
    }
    function yakuCatCommit(input) {
      if (!input) return false;
      if (input.hasAttribute('data-yaku-original') && input.value === input.getAttribute('data-yaku-original')) return false;
      // 「元の値」を更新するのは保存が成功してから。先に更新すると、
      // 保存に失敗した行が「保存済み」と見なされて二度と送られない。
      yakuCatSaveSegment(parseInt(input.getAttribute('data-yaku-cat-input'), 10), input.value);
      input.setAttribute('data-yaku-original', input.value);
      return true;
    }
    document.addEventListener('focusout', function (event) {
      var input = event.target.closest && event.target.closest('[data-yaku-cat-input]');
      if (input) yakuCatCommit(input);
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
      var buttons = document.querySelectorAll('#cat-candidates-list [data-yaku-cat-insert]');
      var pick = buttons[parseInt(event.key, 10) - 1];
      if (!pick) return;
      event.preventDefault();
      yakuCatInsert(input, pick.getAttribute('data-yaku-cat-insert'));
    });
    document.addEventListener('click', function (event) {
      var pick = event.target.closest && event.target.closest('[data-yaku-cat-insert]');
      if (!pick) return;
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
      // 直していなくても「確定」にする。機械訳を読んで「これで良い」と
      // 判断したことは、直したことと同じくらい記録に値する。記録が無いと
      // 翌日再開したときに「どこまで見たか」が分からない。
      var changed = yakuCatCommit(input);
      var index = parseInt(input.getAttribute('data-yaku-cat-input'), 10);
      if (!changed) yakuCatConfirm(index);
      var inputs = Array.prototype.slice.call(document.querySelectorAll('[data-yaku-cat-input]'));
      var pos = inputs.indexOf(input);
      // 次の未確認行へ飛ぶ。確認済みを飛ばせるので、途中から再開できる。
      var next = null;
      for (var i = pos + 1; i < inputs.length; i++) {
        var row = inputs[i].closest('[data-yaku-cat-row]');
        if (!row || row.getAttribute('data-yaku-confirmed') !== '1') { next = inputs[i]; break; }
      }
      if (!next) next = inputs[pos + 1];
      // 全選択しない。次の行の訳が選ばれた状態だと、1打鍵で消えてしまう。
      if (next) { next.focus(); try { next.setSelectionRange(next.value.length, next.value.length); } catch (e) {} }
      else { input.blur(); }
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
      try { translation = yakuDecodeBase64Utf8(toCat.getAttribute('data-yaku-to-cat-translation') || ''); } catch (e) { translation = ''; }
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
      yakuActivateTab('cat');
      yakuCatOpen(translation);
    });
    document.addEventListener('click', function (event) {
      var merge = event.target.closest && event.target.closest('[data-yaku-cat-merge]');
      if (merge) { yakuCatRegroup('merge', parseInt(merge.getAttribute('data-yaku-cat-merge'), 10)); return; }
      var split = event.target.closest && event.target.closest('[data-yaku-cat-split]');
      if (split) { yakuCatRegroup('split', parseInt(split.getAttribute('data-yaku-cat-split'), 10)); }
    });

    document.addEventListener('keydown', function (event) {
      var tab = event.target.closest && event.target.closest('[role="tab"]');
      if (!tab || ['ArrowLeft', 'ArrowRight', 'Home', 'End'].indexOf(event.key) < 0) return;
      event.preventDefault();
      var tabs = Array.prototype.slice.call(document.querySelectorAll('[role="tab"]'));
      var index = tabs.indexOf(tab);
      if (event.key === 'Home') index = 0;
      else if (event.key === 'End') index = tabs.length - 1;
      else index = (index + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length;
      yakuActivateTab(tabs[index].getAttribute('data-yaku-tab'), true);
    });

    document.addEventListener('click', function (event) {
      var element = event.target.closest && event.target.closest('button, [data-yaku-tab]');
      if (!element) return;
      if (element.matches('[data-yaku-tab]')) { yakuActivateTab(element.getAttribute('data-yaku-tab')); return; }
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
      if (element.matches('.history-fill-button')) {
        var input = document.getElementById('input-text');
        if (input) {
          input.value = element.getAttribute('data-yaku-fill-b64') ? yakuDecodeB64(element.getAttribute('data-yaku-fill-b64')) : '';
          yakuActivateTab('text');
          yakuUpdateInputMeta();
          input.focus();
        }
        return;
      }
      if (element.matches('[data-yaku-clear-data]')) {
        var kind = element.getAttribute('data-yaku-clear-data');
        var url = kind === 'diagnostics' ? '/api/clear-diagnostics' : '/api/clear-history';
        var target = document.getElementById('privacy-result');
        var count = kind === 'diagnostics' ? (yakuPrivacyStatus && yakuPrivacyStatus.diagnostic_count) : (yakuPrivacyStatus && yakuPrivacyStatus.history_count);
        var label = kind === 'diagnostics' ? '全文診断データ' : '履歴メタデータと画面内履歴';
        if (!window.confirm(label + ' ' + String(count || 0) + '件を消去します。よろしいですか？')) return;
        element.disabled = true;
        yakuJsonPost(url, {}).then(yakuResponseJson).then(function (data) {
          if (target) target.innerHTML = '<div class="alert alert-success">' + yakuEscape(String(data.count || 0)) + '件を消去しました。</div>';
          if (kind === 'history' && window.htmx) window.htmx.trigger(document.body, 'yaku-history-refresh');
          yakuLoadPrivacyStatus();
        }).catch(function (error) {
          if (target) target.innerHTML = '<div class="alert alert-error">' + yakuEscape(error.message) + '</div>';
        }).finally(function () { element.disabled = false; });
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
    yakuBindEvents();
    yakuUpdateInputMeta();
    var shortcut = document.getElementById('shortcut-mod');
    if (shortcut) shortcut.textContent = /Mac|iPhone|iPad|iPod/.test(navigator.platform || '') ? '⌘' : 'Ctrl';
    yakuResetFileInfoMessage();
    yakuLoadPrivacyStatus();
    yakuRestoreTabJob();
    yakuPollReadyState();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', yakuStart);
  else yakuStart();
}());
