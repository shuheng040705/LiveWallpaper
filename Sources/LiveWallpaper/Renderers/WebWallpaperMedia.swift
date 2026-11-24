import WebKit

/// Applies the host's gain to HTML media while retaining the volume chosen by the page.
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
