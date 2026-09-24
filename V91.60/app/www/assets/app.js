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
  var yakuFileInfoSeq = 0;
  var yakuPrivacyStatus = null;
  var yakuSheetSelection = null;
  var yakuFileDirectionTouched = false;
  var yakuDetailsOpen = {};
  var yakuSettingsSaving = false;
  var yakuActiveTab = 'text';
  var yakuActiveJobKind = 'text';
  var yakuResultByTab = { text: '', file: '' };
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

  // サーバーはエラーも <div class='alert alert-…'> のHTMLで返す。そのまま Error にすると、
  // 呼び出し側がエスケープして画面にタグが文字として出るため、本文と種類に分けて渡す。
  function yakuAlertFromHtml(text) {
    var trimmed = String(text || '').trim();
    if (!/^<div[^>]*class=["'][^"']*\balert\b/i.test(trimmed)) return null;
    var holder = document.createElement('div');
    holder.innerHTML = trimmed;
    var alert = holder.querySelector('.alert');
    if (!alert) return null;
    var kindMatch = /\balert-(error|warning|info|success)\b/.exec(alert.className || '');
    return { message: (alert.textContent || '').trim(), kind: kindMatch ? kindMatch[1] : 'error' };
  }

  function yakuResponseText(response) {
    return response.text().then(function (text) {
      if (!response.ok) {
        var alert = yakuAlertFromHtml(text);
        var error = new Error(alert ? alert.message : (text || ('HTTP ' + response.status)));
        error.status = response.status;
        error.kind = alert ? alert.kind : 'error';
        throw error;
      }
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
    status.innerHTML = '<span class="status-dot ' + yakuStatusClass(klass) + '"></span><span>' + yakuEscape(label || '準備中') + '</span>';
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
    if (data && data.mode === 'login') { gate.removeAttribute('data-yaku-gate'); gate.textContent = 'YakuLingoが開いたEdgeでCopilotにサインインしてください（普段のEdgeとは別なので、初回はサインインが必要です）。サインインすると自動で翻訳できるようになります。'; return; }
    if (data && (data.mode === 'error' || data.mode === 'timeout')) {
      var text = data.mode === 'timeout'
        ? 'Copilotの準備が時間内に終わりませんでした。Edgeの画面（ログインやダイアログ）を確認してから、再接続してください。'
        : 'Copilotの準備に失敗しました。Edgeの画面を確認してから、再接続してください。';
      if (gate.getAttribute('data-yaku-gate') === data.mode) return;
      gate.setAttribute('data-yaku-gate', data.mode);
      gate.innerHTML = '<span>' + yakuEscape(text) + '</span> <button type="button" class="secondary-button" data-yaku-reconnect>Copilotに再接続</button><span class="reconnect-result" aria-live="polite"></span>';
      return;
    }
    gate.removeAttribute('data-yaku-gate');
    gate.textContent = 'Copilotを準備しています';
  }

  function yakuReconnectCopilot(button) {
    var gate = document.getElementById('startup-gate');
    var result = gate ? gate.querySelector('.reconnect-result') : null;
    button.disabled = true;
    yakuJsonPost('/api/copilot/reconnect', {}).then(function (response) {
      return response.json().catch(function () { return {}; }).then(function (data) { return { ok: response.ok, data: data }; });
    }).then(function (res) {
      if (result) result.textContent = (res.data && res.data.message) || '';
      if (res.ok && gate) gate.removeAttribute('data-yaku-gate');
      yakuPollReadyState();
    }).catch(function (error) {
      if (result) result.textContent = error.message;
    }).finally(function () { button.disabled = false; });
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
      yakuSetStatus('準備中', 'warn');
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
      direction.classList.remove('meta-alert');
      if (!value.trim()) direction.textContent = '未入力';
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
    if (name) name.textContent = hasFile ? '別のファイルに替えるときは、もう一度ドロップまたはクリック' : 'ローカルパス指定も利用できます';
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
    yakuActiveJobKind = kind === 'file' ? 'file' : 'text';
    yakuTranslating = true;
    try {
      sessionStorage.setItem('yaku-job-id', jobId);
      sessionStorage.setItem('yaku-job-kind', kind === 'file' ? 'file' : 'text');
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
      var kind = error && error.kind === 'warning' ? 'warning' : 'error';
      var errorHtml = '<div class="alert alert-' + kind + '">' + yakuEscape(error && error.message ? error.message : fallback) + '</div>';
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
    if (!text.trim()) {
      var direction = document.getElementById('direction-indicator');
      if (direction) { direction.textContent = '翻訳するテキストを入力してください'; direction.classList.add('meta-alert'); }
      if (input) input.focus();
      return;
    }
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
      if (yakuUploadedFile && yakuUploadedFile.fingerprint === fingerprint) {
        if (yakuUploadedFile.handle) return Promise.resolve({ file_handle: yakuUploadedFile.handle });
        if (yakuUploadedFile.pending) return yakuUploadedFile.pending;
      }
      yakuUpdateFileMeta('ファイルを安全にアップロードしています（' + yakuFormatBytes(file.size) + '）');
      var pending = yakuFetch('/api/upload', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/octet-stream',
          'X-Yaku-File-Name': encodeURIComponent(file.name)
        },
        body: file
      }).then(yakuResponseJson).then(function (data) {
        if (!data.file_handle) throw new Error('アップロードハンドルを取得できませんでした。');
        if (yakuUploadedFile && yakuUploadedFile.pending === pending) yakuUploadedFile = { fingerprint: fingerprint, handle: data.file_handle };
        return { file_handle: data.file_handle };
      }, function (error) {
        if (yakuUploadedFile && yakuUploadedFile.pending === pending) yakuUploadedFile = null;
        throw error;
      });
      yakuUploadedFile = { fingerprint: fingerprint, handle: '', pending: pending };
      return pending;
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
    var seq = ++yakuFileInfoSeq;
    yakuUpdateFileMeta('ファイル内容を確認しています（翻訳方向と対象シートを調べます）');
    yakuBuildFilePayload().then(function (payload) {
      return yakuJsonPost('/api/file-info', payload).then(yakuResponseJson);
    }).then(function (data) {
      // 確認中に別のファイルへ選び直したり、翻訳を始めたりしたときは、古い結果で上書きしない。
      if (seq !== yakuFileInfoSeq) return;
      if (yakuTranslating) { yakuResetFileInfoMessage(); return; }
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
      var sheetNames = sheets.map(function (sheet) { return String(sheet.Name || ''); }).filter(Boolean);
      // CSV などシートの無いファイルは、選択の対象が無いだけなので「全シート未選択」と扱わない。
      yakuSheetSelection = sheetNames.length ? sheetNames : null;
      if (sheetInput) sheetInput.value = sheetNames.join(', ');
      var reflectedText = reflected ? ' / 推定方向を反映しました' : '';
      var warning = '<div id="sheet-selection-warning" class="alert-inline" hidden>対象シートが選択されていません。チップを選択するか、対象シート欄を空欄に戻すと全シートが対象になります。</div>';
      yakuUpdateFileMeta('<strong>確認OK</strong>：' + yakuEscape(data.FileName || '') + ' / 推定方向 ' + detected + reflectedText + (chips ? '<div class="sheet-chip-row" aria-label="対象シート">' + chips + '</div>' + warning : ''));
      yakuUpdateFileButton();
    }).catch(function (error) {
      if (seq !== yakuFileInfoSeq) return;
      if (yakuTranslating) { yakuResetFileInfoMessage(); return; }
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
    var target = name === 'file' ? 'file' : 'text';
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
      yakuFileInfoSeq += 1;
      yakuResetFileInfoMessage();
      // 選んだらすぐ確認し、翻訳方向と対象シートを反映する（ボタンは確認し直す用に残す）。
      if (fileInput.files.length) yakuSubmitFileInfo();
    });
    if (filePath) filePath.addEventListener('input', function () {
      if (filePath.value.trim() && fileInput) fileInput.value = '';
      yakuUploadedFile = null;
      yakuSheetSelection = null;
      yakuFileDirectionTouched = false;
      yakuFileInfoSeq += 1;
      yakuResetFileInfoMessage();
    });
    if (filePath) filePath.addEventListener('change', function () {
      if (filePath.value.trim()) yakuSubmitFileInfo();
    });
    if (fileInfoButton) fileInfoButton.addEventListener('click', yakuSubmitFileInfo);
    if (fileSheets) fileSheets.addEventListener('input', function () { yakuSheetSelection = null; yakuUpdateFileButton(); });
    Array.prototype.forEach.call(document.querySelectorAll('input[name="file_direction"]'), function (radio) {
      radio.addEventListener('change', function () { yakuFileDirectionTouched = true; });
    });
    if (fileClearButton) fileClearButton.addEventListener('click', function () {
      if (fileInput) fileInput.value = '';
      yakuFileInfoSeq += 1;
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
      var form = event.target.closest && event.target.closest('form[data-yaku-json-post]');
      if (!form) return;
      event.preventDefault();
      yakuSubmitJsonForm(form);
    });

    document.addEventListener('input', function (event) {
      var form = event.target.closest && event.target.closest('form[data-yaku-settings-form]');
      if (form) yakuMarkSettingsDirty(form);
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
      if (element.matches('[data-yaku-reconnect]')) { yakuReconnectCopilot(element); return; }
      if (element.matches('[data-yaku-quit]')) { yakuQuit(element); return; }
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

    // 用語の追加（自分の用語集へ保存。版を更新しても残る）
    document.addEventListener('submit', function (event) {
      var form = event.target;
      if (!form || !form.matches || !form.matches('[data-yaku-glossary-add]')) return;
      event.preventDefault();
      var panel = document.getElementById('glossary-panel');
      var result = form.querySelector('.glossary-add-result');
      var button = form.querySelector('button[type="submit"]');
      var data = {
        source: (form.elements.source && form.elements.source.value) || '',
        target: (form.elements.target && form.elements.target.value) || '',
        kind: (form.elements.kind && form.elements.kind.value) || 'prompt'
      };
      if (button) button.disabled = true;
      yakuJsonPost('/api/glossary/add', data).then(function (response) {
        return response.text().then(function (html) { return { ok: response.ok, html: html }; });
      }).then(function (res) {
        if (res.ok && panel) {
          panel.innerHTML = res.html;
          var next = panel.querySelector('[data-yaku-glossary-add] input[name="source"]');
          if (next) next.focus();
        } else if (result) {
          result.innerHTML = res.html;
        }
      }).catch(function (error) {
        if (result) result.innerHTML = '<div class="alert alert-error">' + yakuEscape(error.message) + '</div>';
      }).finally(function () { if (button) button.disabled = false; });
    });
    document.addEventListener('click', function (event) {
      var opener = event.target.closest && event.target.closest('[data-yaku-open-glossary-folder]');
      if (!opener) return;
      var form = opener.closest('form');
      var result = form ? form.querySelector('.glossary-add-result') : null;
      opener.disabled = true;
      yakuJsonPost('/api/glossary/open-folder', {}).then(yakuResponseText).then(function (html) {
        if (result) result.innerHTML = html;
      }).catch(function (error) {
        if (result) result.innerHTML = '<div class="alert alert-error">' + yakuEscape(error.message) + '</div>';
      }).finally(function () { opener.disabled = false; });
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

  function yakuQuit(button) {
    var question = yakuTranslating ? '翻訳中です。中断してYakuLingoを終了しますか？' : 'YakuLingoを終了しますか？';
    if (!window.confirm(question)) return;
    button.disabled = true;
    window.clearTimeout(yakuPollTimer);
    window.clearTimeout(yakuJobTimer);
    yakuJsonPost('/shutdown', {}).catch(function () { return null; }).then(function () {
      document.body.innerHTML = '<main class="shell"><div class="alert alert-info">YakuLingoを終了しました。このタブは閉じてかまいません。もう一度使うときは「YakuLingo起動」から起動してください。</div></main>';
      try { window.close(); } catch (e) { /* 開いたのがスクリプトでなければ閉じられない */ }
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
