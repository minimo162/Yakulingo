import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const read=(...parts)=>fs.readFileSync(path.join(root,...parts),'utf8');
const quick=read('www','quick.html');
const js=read('www','assets','quick-page.js');
const css=read('www','assets','quick-page.css');
const cat=read('www','cat.html');
const server=read('src','Server.ps1');
const readme=read('..','README.md');
const design=read('DESIGN.md');
const build=read('config','build.txt').replace(/^\uFEFF/,'').trim();
const failures=[];
const check=(ok,message)=>{if(!ok)failures.push(message)};

check(quick.includes('<title>テキスト翻訳 - YakuLingo</title>'),'page title is not text translation');
check(quick.includes('href="/quick" aria-label="YakuLingo テキスト翻訳"'),'brand does not return to text translation');
check(quick.includes('aria-current="page">テキスト翻訳</a>')&&quick.includes('>Excel翻訳</a>'),'two-mode navigation is not normalized');
for(const id of ['quick-page-input','quick-page-output','quick-page-direction','quick-page-swap','quick-page-clear','quick-page-copy','quick-page-submit','quick-rewrite-actions','quick-page-undo'])check(quick.includes('id="'+id+'"'),'missing '+id);
for(const removed of ['quick-display-details','quick-purpose','quick-length','quick-font','quick-font-size','quick-column-width','quick-lines','quick-target-chars','quick-percent','quick-wrap','quick-merged','quick-preserve','quick-fit-estimate'])check(!quick.includes(removed),'removed display control remains: '+removed);
check(!quick.includes('短文・セル向け')&&!quick.includes('<h1>文章を翻訳</h1>'),'legacy centered heading remains');
check(quick.includes('数値は伏せて送ります')&&quick.includes('社名・人名と文章'),'privacy disclosure is missing');

for(const removed of ['function displayContext','function estimate','function optimizationChip','autoOptimized','display_context'])check(!js.includes(removed),'removed display behavior remains: '+removed);
check(js.includes("var request={text:text,direction_intent:direction.value||'auto'}"),'initial request is not minimal');
check(js.includes("start('/api/palette/chip'")&&js.includes('current_text:lastMasked'),'explicit result rewrite is not wired');
check(js.includes('host.hidden=variants.length<2'),'variants are not conditional on two or more results');
check(js.includes('yakuQuickHandoff')&&js.includes('yakuQuickReturn'),'Excel round trip is missing');
check(!/finish\([\s\S]*setTimeout\(function\(\)\{rewrite/.test(js),'first translation still auto-starts a rewrite');
new Function(js);

check(server.includes("$path -in @('/', '/quick', '/palette')")&&server.includes("-PageName 'quick.html'"),'root does not serve text translation');
check(server.includes("$path -eq '/cat'")&&server.includes("-PageName 'cat.html'"),'Excel route is not separate');
check(!server.includes("payload['display_context']")&&!server.includes('次の表示条件は厳密な収まり保証ではなく'),'server still consumes display_context');
check(cat.includes('href="/quick" aria-label="YakuLingo テキスト翻訳へ戻る"'),'Excel brand does not return to text translation');
check(cat.includes('>テキスト翻訳</a>')&&cat.includes('aria-current="page">Excel翻訳</a>'),'Excel navigation labels are not normalized');

check(css.includes('body.app-quick button.quick-primary-button')&&css.includes('color:#fff'),'primary contrast rule is missing');
check(css.includes('body.app-quick button.quick-secondary-button')&&css.includes('color:#263247'),'secondary contrast rule is missing');
check(css.includes('body.app-quick button:disabled')&&css.includes('opacity:1'),'disabled labels can disappear');
check(css.includes('button:focus-visible')&&css.includes('outline:3px solid'),'keyboard focus is not visible');
check(css.includes('@media(max-width:900px)')&&css.includes('grid-template-columns:1fr'),'stacked narrow layout is missing');

check(readme.includes('起動すると')&&readme.includes('**テキスト翻訳**'),'README does not describe the text-first entry');
check(!readme.includes('表示条件は短くする目安'),'README still documents display conditions');
check(design.includes('Text translation does not collect display conditions'),'DESIGN does not remove display conditions');
check(build==='V91.63','build id is not V91.63');

if(failures.length){for(const failure of failures)console.error('not ok - '+failure);process.exit(1)}
console.log('ok - Issue #129 text-first UI contract');
