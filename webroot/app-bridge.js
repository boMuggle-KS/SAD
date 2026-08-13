// 应用内宿主的 ksu 桥接：window.ksu 已存在时整体跳过。模块不再提供
// 管理器宿主 WebUI，控制应用是唯一宿主，由本文件注入 window.ksu。
// 应用通过 __strNativeBridge（Android JSInterface）把命令转发给模块侧
// root 执行，结果由原生层以 window.__strCb_<id>(errno, stdout, stderr) 回推。
(function () {
  if (window.ksu || !window.__strNativeBridge) return;
  window.ksu = {
    exec: function (cmd, options, callback) {
      if (typeof callback === "function") {
        var id = "str_" + Date.now() + "_" + Math.random().toString(36).slice(2);
        window["__strCb_" + id] = function (errno, stdout, stderr) {
          try { delete window["__strCb_" + id]; } catch (e) {}
          try { callback(errno, stdout, stderr); } catch (e) {}
        };
        __strNativeBridge.exec(cmd, id);
        return undefined;
      }
      // 同步形式无法跨进程返回：抛错让调用方（probeBridgeSync）捕获后回退异步形式
      throw new Error("sync exec unavailable in app host");
    }
  };
})();
