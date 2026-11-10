// SPDX-License-Identifier: GPL-3.0-only
// Shared document from geetest_dialog.dart, whose inline bridge was adapted
// from PiliPlus (d9e9626f1a3f89cd9ca85e18f61aaba02634e12a). Official GeeTest v4.
import 'dart:convert';

const _fields = [
  'captcha_id',
  'lot_number',
  'pass_token',
  'gen_time',
  'captcha_output',
];

Map<String, dynamic>? parseGeetestResult(Object? raw, String captchaId) {
  if (raw is! Map ||
      raw.length != _fields.length ||
      _fields.any(
        (key) =>
            raw[key] is! String ||
            !RegExp(r'^[\x21-\x7e]{1,8192}$').hasMatch(raw[key] as String),
      ) ||
      raw['captcha_id'] != captchaId) {
    return null;
  }
  return {for (final key in _fields) key: raw[key]};
}

/// A bridge nonce selects the embedded view; otherwise POST to the same-origin
/// one-time result endpoint. Neither document receives a phone number or login.
String geetestDocument(String captchaId, {String? bridgeNonce}) {
  final id = jsonEncode(captchaId);
  final emit = bridgeNonce != null
      ? '''const nonce=${jsonEncode(bridgeNonce)};
  const emit=(kind,value)=>{if(window===window.top) window.flutter_inappwebview.callHandler('xmlyCaptcha',nonce,kind,value);};'''
      : '''let submitting=false;
  const emit=(kind,value)=>{
    if(kind!=='success'||submitting||window!==window.top)return;
    submitting=true;
    const status=document.getElementById('status');
    status.textContent='正在返回验证结果…';
    fetch('result',{method:'POST',headers:{'Content-Type':'application/json'},credentials:'omit',cache:'no-store',body:JSON.stringify(value)})
      .then(response=>{if(!response.ok)throw new Error();status.textContent='安全验证已完成，请回到 XMPlus 继续。';document.getElementById('verify').hidden=true;})
      .catch(()=>{status.textContent='未能返回验证结果，请回到 XMPlus 重新打开浏览器验证。';});
  };''';
  final load = bridgeNonce != null
      ? '''if(window.flutter_inappwebview?.callHandler){load();}
  else{window.addEventListener('flutterInAppWebViewPlatformReady',load,{once:true});}'''
      : 'load();';
  return '''<!doctype html><html><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' https://*.geetest.com https://*.geevisit.com https://*.gsensebot.com; connect-src 'self' https://*.geetest.com https://*.geevisit.com https://*.gsensebot.com; img-src data: blob: https://*.geetest.com https://*.geevisit.com https://*.gsensebot.com; style-src 'unsafe-inline' https://*.geetest.com; font-src data: https://*.geetest.com; frame-src https://*.geetest.com https://*.geevisit.com https://*.gsensebot.com; object-src 'none'; base-uri 'none'; form-action 'none'">
<title>XMPlus 安全验证</title>
<style>body{font:16px sans-serif;text-align:center;padding:20px}button{font:inherit;padding:12px}</style>
</head><body><p id="status">正在加载安全验证…</p><button id="verify" hidden>开始验证</button>
<script>
(() => {
  $emit
  const fail=()=>{document.getElementById('status').textContent='安全验证加载失败，请关闭后重试';emit('error',null);};
  const start=()=>{
    if(typeof initGeetest4!=='function'){fail();return;}
    initGeetest4({captchaId:$id,product:'bind',language:'zho',protocol:'https://',onError:fail,offlineCb:fail},captcha=>{
      captcha.onReady(()=>{
        document.getElementById('status').textContent='请完成安全验证';
        const button=document.getElementById('verify');button.hidden=false;
        button.onclick=()=>captcha.showCaptcha();emit('ready',null);
        captcha.showCaptcha();
      }).onSuccess(()=>{
        const v=captcha.getValidate();
        if(!v){fail();return;}
        const out={captcha_id:$id};
        ['lot_number','pass_token','gen_time','captcha_output'].forEach(k=>out[k]=v[k]);
        emit('success',out);
      }).onError(fail).onClose(()=>emit('close',null));
    });
  };
  const load=()=>{const script=document.createElement('script');script.src='https://static.geetest.com/v4/gt4.js';script.onload=start;script.onerror=fail;document.head.appendChild(script);};
  $load
})();
</script></body></html>''';
}
