pragma ComponentBehavior: Bound
import QtQuick

// Plays lighter copies of the videos (downscaled to the screen resolution and
// with a limited frame rate) generated in the background by tools/optimize_video.sh
Item {
    id: root
    property bool active: true
    property bool downscale: true
    property int targetWidth: 0
    property int targetHeight: 0
    // 0 disables the limit
    property int maxFps: 30
    property bool debugEnabled: false
    property string instanceId: ""

    readonly property bool ready: !active || !downscale || (targetWidth > 0 && targetHeight > 0)
    readonly property string settingsKey: active ? `${downscale ? targetWidth : 0}x${downscale ? targetHeight : 0}@${maxFps}` : "disabled"
    readonly property string tool: Qt.resolvedUrl("./tools/optimize_video.sh").toString().substring(7)

    // the source of the video that is playing now became available
    signal optimized(string original, string optimizedUrl)

    property var _transcoding: ({})
    property var _failed: ({})
    property var _pending: []
    property int _requestCount: 0

    function printLog(...args) {
        if (debugEnabled) {
            console.log("VideoOptimizer:", ...args);
        }
    }

    function toLocalPath(url) {
        url = url.toString();
        if (url.startsWith("/")) {
            return url;
        }
        if (!url.startsWith("file://")) {
            return "";
        }
        const path = url.substring(7);
        try {
            return decodeURIComponent(path);
        } catch (e) {
            return path;
        }
    }

    function toUrl(path) {
        return "file://" + encodeURI(path);
    }

    function shellQuote(value) {
        return "'" + value.split("'").join("'\\''") + "'";
    }

    function run(mode, path, callback) {
        const width = downscale ? targetWidth : 0;
        const height = downscale ? targetHeight : 0;
        // the trailing comment makes each command unique, the executable engine
        // can't run the same command more than once at a time
        const cmd = `bash ${shellQuote(tool)} ${mode} ${shellQuote(path)} ${width} ${height} ${maxFps} # ${instanceId}-${++_requestCount}`;
        printLog(cmd);
        runCommand.exec(cmd, callback);
    }

    // Calls callback(url, settingsKey) with the url that should be played for
    // filename, starting the generation of an optimized copy in the background
    // when needed
    function resolve(filename, callback) {
        const path = toLocalPath(filename ?? "");
        if (!active || !path) {
            callback(filename, settingsKey);
            return;
        }
        if (!ready) {
            _pending.push([filename, callback]);
            readyTimeout.restart();
            return;
        }
        const usedSettingsKey = settingsKey;
        const key = `${path}|${usedSettingsKey}`;
        run("resolve", path, output => {
            const line = output.stdout.trim().split("\n").pop() ?? "";
            if (output.exitCode === 0 && line.startsWith("CACHED ")) {
                const optimizedUrl = toUrl(line.substring(7));
                printLog("using optimized copy", optimizedUrl);
                callback(optimizedUrl, usedSettingsKey);
                return;
            }
            callback(filename, usedSettingsKey);
            if (output.exitCode === 0 && line === "NEEDED") {
                transcode(filename, path, key);
            } else if (output.exitCode !== 0) {
                console.warn("VideoOptimizer: resolve failed", output.exitCode, output.stderr);
            }
        });
    }

    function transcode(filename, path, key) {
        if (_transcoding[key] || _failed[key]) {
            return;
        }
        _transcoding[key] = true;
        printLog("optimizing", path);
        run("transcode", path, output => {
            delete _transcoding[key];
            const optimizedPath = output.stdout.trim().split("\n").pop() ?? "";
            if (output.exitCode !== 0 || !optimizedPath) {
                _failed[key] = true;
                console.warn("VideoOptimizer: failed to optimize", path, output.stderr);
                return;
            }
            // the settings changed while transcoding, the result is no longer valid
            if (key !== `${path}|${settingsKey}`) {
                return;
            }
            printLog("optimized", optimizedPath);
            optimized(filename, toUrl(optimizedPath));
        });
    }

    function flushPending() {
        const pending = _pending;
        _pending = [];
        for (const [filename, callback] of pending) {
            resolve(filename, callback);
        }
    }

    onReadyChanged: {
        if (ready) {
            readyTimeout.stop();
            flushPending();
        }
    }

    // don't hold the videos forever if the screen size never becomes available
    Timer {
        id: readyTimeout
        interval: 3000
        onTriggered: {
            const pending = root._pending;
            root._pending = [];
            for (const [filename, callback] of pending) {
                callback(filename, root.settingsKey);
            }
        }
    }

    RunCommand {
        id: runCommand
    }
}
