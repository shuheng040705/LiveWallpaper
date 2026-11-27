import WebKit

/// Coordinates host gain, playback policy and local video looping with WebKit.
enum WebWallpaperMedia {
    static let script = #"""
    (() => {
        let gain = 0;
        const proto = HTMLMediaElement.prototype;
        const volume = Object.getOwnPropertyDescriptor(proto, 'volume');
        const play = proto.play;
        const levels = new WeakMap();
        const elements = new Set();
        const cleanup = new FinalizationRegistry(ref => elements.delete(ref));
        const pendingLoopChecks = new WeakSet();
        let hostPaused = false;
        let playbackRevision = 0;

        function track(element) {
            if (!levels.has(element)) {
                levels.set(element, volume.get.call(element));
                const ref = new WeakRef(element);
                elements.add(ref);
                cleanup.register(element, ref);
            }
        }

        function applyGain(element) {
            const effective = levels.get(element) * gain;
            if (volume.get.call(element) !== effective) volume.set.call(element, effective);
        }

        // Some local WebM files have no seekable range. On a repeat, WebKit can
        // remain at duration with loop=true, paused=false and ended=false.
        function nearEnd(video) {
            // WebKit can mark a still-visible desktop window hidden under Stage Manager.
            // The wallpaper host and the element itself decide whether playback is paused.
            return !hostPaused && video instanceof HTMLVideoElement &&
                video.loop && !video.paused && !video.error && video.playbackRate > 0 &&
                video.currentSrc.startsWith('lwwp://wp/') && Number.isFinite(video.duration) &&
                video.currentTime > 0 && video.duration - video.currentTime <= Math.max(1, video.playbackRate * 0.5);
        }

        function checkLoop(video) {
            if (!nearEnd(video) || pendingLoopChecks.has(video)) return;
            pendingLoopChecks.add(video);
            const revision = playbackRevision, src = video.currentSrc, time = video.currentTime;
            const frames = video.getVideoPlaybackQuality().totalVideoFrames;
            setTimeout(() => {
                pendingLoopChecks.delete(video);
                if (!nearEnd(video)) return;
                if (revision === playbackRevision && src === video.currentSrc &&
                    video.duration - video.currentTime < 0.25 && video.currentTime === time &&
                    frames === video.getVideoPlaybackQuality().totalVideoFrames) {
                    const rate = video.playbackRate;
                    video.load();
                    if (video.playbackRate !== rate) video.playbackRate = rate;
                    video.play().catch(() => {});
                } else {
                    checkLoop(video);
                }
            }, 900);
        }
        // Only arm a timer near the end of a playing loop. A normal native rewind
        // cancels recovery, even for a short clip which laps the timer interval.
        for (const event of ['timeupdate', 'waiting', 'stalled']) {
            document.addEventListener(event, e => checkLoop(e.target), true);
        }
        function playbackPolicyChanged() {
            playbackRevision++;
            if (!hostPaused) {
                for (const ref of elements) checkLoop(ref.deref());
            }
        }
        document.addEventListener('visibilitychange', playbackPolicyChanged);
        window.__lwSetHostMediaPaused = paused => {
            hostPaused = paused;
            playbackPolicyChanged();
        };

        Object.defineProperty(proto, 'volume', {
            ...volume,
            get() { return levels.get(this) ?? volume.get.call(this); },
            set(value) {
                const level = Number(value);
                if (!(level >= 0 && level <= 1)) return volume.set.call(this, value);
                track(this);
                levels.set(this, level);
                applyGain(this);
            }
        });
        // Voice lines often use new Audio() without ever inserting it into the document.
        proto.play = function(...args) {
            track(this);
            applyGain(this);
            return play.apply(this, args);
        };
        document.addEventListener('play', event => {
            if (event.target instanceof HTMLMediaElement) {
                track(event.target);
                applyGain(event.target);
            }
        }, true);
        window.__lwSetMediaGain = value => {
            gain = value;
            for (const ref of elements) {
                const element = ref.deref();
                if (element) applyGain(element);
            }
        };
    })();
    """#
}
