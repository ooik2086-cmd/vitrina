// The 3D stage in a browser frame: what the page says goes to the app around it, and the app's calls come back in,
// as window messages. Only the stage's own calls are taken, and only from the app that holds this frame; they run in
// the order sent.
(function () {
  var calls = { load: 1, setVariant: 1, setBackground: 1, setPaused: 1, view: 1 };
  var queue = Promise.resolve();
  var kept = {};
  window.Vitrina = { postMessage: function (m) { parent.postMessage({ vitrina: String(m) }, '*'); } };

  // A site that may not serve binary models keeps each beside its address as base64 text (MODEL.glb.txt): read
  // from there into the browser's memory; where there is no such text, the model itself.
  function model(url) {
    if (typeof url !== 'string' || !/\.glb$/.test(url)) return Promise.resolve(url);
    if (!kept[url]) {
      kept[url] = fetch(url + '.txt').then(function (t) {
        if (!t.ok) return url;
        return t.text().then(function (text) {
          var bytes = atob(text.trim()), data = new Uint8Array(bytes.length);
          for (var i = 0; i < bytes.length; i++) data[i] = bytes.charCodeAt(i);
          return URL.createObjectURL(new Blob([data], { type: 'model/gltf-binary' }));
        });
      }).catch(function () { return url; });
    }
    return kept[url];
  }

  function call(d) {
    // The page's own load runs on by itself (it says when the shoe is drawn): the calls after it do not wait for it.
    if (d.call !== 'load' || !d.args[0]) {
      var v = window.vitrina[d.call].apply(null, d.args);
      return d.call === 'view' ? v : null;
    }
    var a = d.args[0];
    return Promise.all([model(a.url), model(a.hq)]).then(function (u) {
      a.url = u[0];
      a.hq = u[1];
      window.vitrina.load(a);
      return null;
    });
  }

  addEventListener('message', function (e) {
    var d = e.data;
    if (e.source !== parent || !d || !calls[d.call] || !window.vitrina) return;
    d.args = Array.isArray(d.args) ? d.args : [];
    queue = queue.then(function () { return call(d); }).then(function (v) { return v; }, function () { return null; })
      .then(function (value) {
        if (typeof d.id === 'number') parent.postMessage({ answer: d.id, value: value === undefined ? null : JSON.stringify(value) }, '*');
      });
  });
})();
