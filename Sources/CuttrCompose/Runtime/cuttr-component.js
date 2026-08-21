// cuttr's component runtime: a Remotion-shaped subset, in the browser macOS
// already has.
//
// A component is a function of one number. It is handed a frame index and it
// hands back a picture of that frame — no clock, no animation loop, nothing
// that carries state from one frame to the next. That is not a style choice:
// `ComponentBaker` drives this to frame n, snapshots it, and moves on, so
// anything that depended on *when* it ran would come out differently on the
// next bake and the file would stop being the product.
//
// Everything a component is given is an argument to it (see `mount` below),
// not a global, so a component cannot quietly rely on something this runtime
// happens to leave lying about — and so that the list of what exists is one
// line of Swift and one line of JavaScript rather than a survey of the page.
//
// What is deliberately *not* here is written down in `Component`'s doc comment,
// which is the one somebody reads before writing a file. Keep the two in step.

(function (global) {
	'use strict';

	// ---- Determinism, enforced ----------------------------------------------
	//
	// Asking nicely is not enough: `Date.now()` and `Math.random()` are one
	// keystroke away and neither of them fails visibly. So the page they run in
	// does not have them.
	//
	// **This file must be the last script on the page, and that is load-bearing.**
	// `react-dom.min.js` calls `Math.random()` twice while it is being evaluated,
	// to make the suffixes of its own expando property names — `__reactFiber$…`.
	// Those never reach the DOM and never reach a pixel, so they are harmless;
	// but if this ran first, React would throw before a component had been
	// written, and the error would name a line in a minified bundle. See
	// `ComponentBaker.Runtime.page`, which is where the order is set.

	// The clock reads the epoch. Frozen rather than removed, because React's own
	// scheduler reads it and a component that prints a date should come out
	// obviously wrong — 1970 — rather than fail to bake at all. A component that
	// wants today's date takes it as a prop, which puts it in the hash where it
	// belongs.
	var RealDate = global.Date;
	function Frozen(a, b, c, d, e, f, g) {
		if (!(this instanceof Frozen)) return new RealDate(0).toString();
		if (arguments.length === 0) return new RealDate(0);
		return new RealDate(a, b, c, d, e, f, g);
	}
	Frozen.prototype = RealDate.prototype;
	Frozen.now = function () { return 0; };
	Frozen.parse = RealDate.parse;
	Frozen.UTC = RealDate.UTC;
	global.Date = Frozen;

	Math.random = function () {
		throw new Error('Math.random() is not available in a component, because a '
			+ 'render that cannot be repeated is not a render. Use random(seed).');
	};

	// Nothing may be fetched. There is a content rule list blocking every load
	// as well — that one catches an <img src="https://…"> and a webfont, which
	// no amount of overwriting `fetch` would — and this is here for the error
	// message, so the component's author is told why rather than shown a hole.
	['fetch', 'XMLHttpRequest', 'WebSocket', 'EventSource'].forEach(function (name) {
		global[name] = function () {
			throw new Error(name + ' is not available in a component: a component that '
				+ 'fetches renders something different every time. Pass the numbers in '
				+ 'as props, or bake the data into the file.');
		};
	});

	// An animation loop is the other clock. A component that wants one has
	// misunderstood what it is: it is asked for frame n and only frame n.
	global.requestAnimationFrame = function () {
		throw new Error('requestAnimationFrame is not available in a component. '
			+ 'A component draws one frame; use useCurrentFrame().');
	};

	// How many lines `new Function` puts in front of a body. Measured rather
	// than assumed, so that when a component throws, the line reported is the
	// line somebody wrote — and so that a JavaScriptCore that starts counting
	// differently does not silently start reporting the wrong one.
	var offset = (function () {
		try { new Function('throw new Error("probe")')(); } catch (e) { return (e.line || 1) - 1; }
		return 0;
	})();

	// ---- The subset ---------------------------------------------------------

	var React = global.React;
	var ReactDOM = global.ReactDOM;
	var h = React.createElement;
	var FrameContext = React.createContext(0);

	/** The frame being drawn, counted from the start of the component. */
	function useCurrentFrame() { return React.useContext(FrameContext); }

	var config = {};
	var props = {};

	/** The frame's size, the rate, and how many frames there are. */
	function useVideoConfig() { return config; }

	/** What the project file passed in `props:`. Strings, as a scene's are. */
	function useProps() { return props; }

	/// A stretch of the component's life, on its own clock.
	///
	/// Children inside see frame nought at `from`, which is the whole point:
	/// a title that arrives at second two is written as though it arrived at
	/// second nought and moved into a `<Sequence>`.
	function Sequence(spec) {
		var parent = useCurrentFrame();
		var from = spec.from || 0;
		var local = parent - from;
		if (local < 0) return null;
		if (spec.durationInFrames != null && local >= spec.durationInFrames) return null;
		var inner = spec.layout === 'none'
			? spec.children
			: h('div', {style: {position: 'absolute', left: 0, top: 0,
			                    width: '100%', height: '100%'}}, spec.children);
		return h(FrameContext.Provider, {value: local}, inner);
	}

	/// One number mapped onto another, over one or more segments.
	///
	/// The same signature and the same defaults as Remotion's, because somebody
	/// arriving from there should not have to find out by experiment that this
	/// one clamps where that one extends.
	function interpolate(input, inputRange, outputRange, options) {
		options = options || {};
		if (inputRange.length !== outputRange.length) {
			throw new Error('interpolate: inputRange and outputRange must be the same length');
		}
		if (inputRange.length < 2) {
			throw new Error('interpolate: needs at least two stops');
		}
		var left = options.extrapolateLeft || 'extend';
		var right = options.extrapolateRight || 'extend';
		var easing = options.easing;

		if (input < inputRange[0]) {
			if (left === 'clamp') return outputRange[0];
			if (left === 'identity') return input;
		}
		var last = inputRange.length - 1;
		if (input > inputRange[last]) {
			if (right === 'clamp') return outputRange[last];
			if (right === 'identity') return input;
		}
		var i = 0;
		while (i < last - 1 && input >= inputRange[i + 1]) i++;
		var a = inputRange[i], b = inputRange[i + 1];
		var from = outputRange[i], to = outputRange[i + 1];
		if (b === a) return to;
		var t = (input - a) / (b - a);
		if (easing) t = easing(t);
		return from + t * (to - from);
	}

	/// A damped spring from nought to one, evaluated at a frame.
	///
	/// The same oscillator Remotion's `spring` uses, with the same default
	/// config, so a number tuned there means the same thing here.
	function spring(spec) {
		var c = spec.config || {};
		var damping = c.damping == null ? 10 : c.damping;
		var mass = c.mass == null ? 1 : c.mass;
		var stiffness = c.stiffness == null ? 100 : c.stiffness;
		var from = spec.from == null ? 0 : spec.from;
		var to = spec.to == null ? 1 : spec.to;
		var t = Math.max(0, spec.frame) / (spec.fps || 25);
		var zeta = damping / (2 * Math.sqrt(stiffness * mass));
		var omega0 = Math.sqrt(stiffness / mass);
		var span = to - from;
		var value;
		if (zeta < 1) {
			var omega1 = omega0 * Math.sqrt(1 - zeta * zeta);
			var envelope = Math.exp(-zeta * omega0 * t);
			value = to - envelope * (
				((zeta * omega0 * span) / omega1) * Math.sin(omega1 * t)
				+ span * Math.cos(omega1 * t));
		} else {
			var flat = Math.exp(-omega0 * t);
			value = to - flat * (span + omega0 * span * t);
		}
		if (c.overshootClamping) {
			value = to > from ? Math.min(value, to) : Math.max(value, to);
		}
		return value;
	}

	/// Curves for `interpolate`'s `easing`.
	var Easing = {
		linear: function (t) { return t; },
		quad: function (t) { return t * t; },
		cubic: function (t) { return t * t * t; },
		sin: function (t) { return 1 - Math.cos((t * Math.PI) / 2); },
		circle: function (t) { return 1 - Math.sqrt(1 - t * t); },
		in: function (easing) { return easing; },
		out: function (easing) { return function (t) { return 1 - easing(1 - t); }; },
		inOut: function (easing) {
			return function (t) {
				return t < 0.5 ? easing(t * 2) / 2 : 1 - easing((1 - t) * 2) / 2;
			};
		},
		/// A CSS cubic-bezier, solved by bisection — twenty iterations puts it
		/// well inside a pixel and takes no measurable time at these counts.
		bezier: function (x1, y1, x2, y2) {
			function curve(a, b, t) {
				var u = 1 - t;
				return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t;
			}
			return function (x) {
				var low = 0, high = 1, mid = x;
				for (var i = 0; i < 20; i++) {
					mid = (low + high) / 2;
					if (curve(x1, x2, mid) < x) low = mid; else high = mid;
				}
				return curve(y1, y2, mid);
			};
		},
	};
	Easing.ease = Easing.bezier(0.42, 0, 1, 1);

	/// A number in [0, 1) that is the same number every time, for a given seed.
	///
	/// The replacement for `Math.random`, and the same bargain the effects make:
	/// a seed exists so that the same file gives the same cloud on every render,
	/// which is why it cannot be animated there and why this takes one here.
	function random(seed) {
		if (seed === null || seed === undefined) {
			throw new Error('random() needs a seed. That is the point of it: the same '
				+ 'seed gives the same number on every render.');
		}
		var text = String(seed);
		var hash = 2166136261;
		for (var i = 0; i < text.length; i++) {
			hash ^= text.charCodeAt(i);
			hash = Math.imul(hash, 16777619);
		}
		// mulberry32, on that hash.
		var a = hash >>> 0;
		a = (a + 0x6D2B79F5) >>> 0;
		var t = a;
		t = Math.imul(t ^ (t >>> 15), t | 1);
		t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
		return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
	}

	// ---- Being driven -------------------------------------------------------

	var registered = null;
	var stage = null;

	/// What the component's file calls to say which function it is.
	function component(fn) { registered = fn; }

	/// The error a component threw, as the line somebody wrote it on.
	///
	/// `e.line` is the innermost frame, which for a component's own mistake is
	/// the line wanted and for one of the guards above is a line inside this
	/// file. Reporting that would send somebody to read the runtime, so a line
	/// outside the source is reported as no line at all — the guards' messages
	/// say everything they need to without one.
	function trouble(e, lines) {
		var line = e && e.line ? e.line - offset : null;
		if (line != null && (line < 1 || line > lines)) line = null;
		return {message: String((e && e.message) || e), line: line};
	}

	/// Which families the rendered frame asks for and this machine has not got.
	///
	/// By measurement, not by `document.fonts.check` — that answers true for a
	/// family nobody has, because a browser's job is to substitute silently and
	/// carry on. Which is exactly the failure worth catching: a substituted
	/// family is a wrong render that nobody is told about.
	function missingFonts() {
		var generic = {
			serif: 1, 'sans-serif': 1, monospace: 1, cursive: 1, fantasy: 1,
			'system-ui': 1, 'ui-serif': 1, 'ui-sans-serif': 1, 'ui-monospace': 1,
			'ui-rounded': 1, '-apple-system': 1, 'BlinkMacSystemFont': 1,
			inherit: 1, initial: 1, unset: 1, revert: 1, '': 1,
		};
		var probe = document.createElement('span');
		probe.style.cssText = 'position:absolute;left:-9999px;top:-9999px;'
			+ 'font-size:100px;white-space:nowrap';
		probe.textContent = 'mmmmmmmmmmlliWWW@';
		document.body.appendChild(probe);

		function present(family) {
			var generics = ['monospace', 'serif', 'sans-serif'];
			for (var i = 0; i < generics.length; i++) {
				probe.style.fontFamily = generics[i];
				var plain = probe.offsetWidth;
				probe.style.fontFamily = '"' + family + '",' + generics[i];
				if (probe.offsetWidth !== plain) return true;
			}
			return false;
		}

		var missing = [], seen = {};
		var all = stage.querySelectorAll('*');
		for (var i = 0; i < all.length; i++) {
			var families = getComputedStyle(all[i]).fontFamily.split(',');
			for (var j = 0; j < families.length; j++) {
				var family = families[j].trim().replace(/^["']|["']$/g, '');
				// `-webkit-standard` and its relatives are what WebKit reports
				// for an element that named no family at all. They are generics
				// with a vendor prefix, not families anybody has installed, and
				// treating one as missing would refuse every component that has
				// a plain <div> in it.
				if (family.indexOf('-webkit-') === 0) continue;
				if (generic[family] || seen[family]) continue;
				seen[family] = 1;
				if (!present(family)) missing.push(family);
			}
		}
		probe.parentNode.removeChild(probe);
		return missing;
	}

	/// Reads the component's file and gets it ready to be drawn.
	///
	/// Answers `null` when it worked, and what went wrong when it did not. A
	/// syntax error surfaces here; a mistake inside the function surfaces at
	/// the first `draw`.
	function mount(source, name, theConfig, theProps) {
		config = theConfig;
		props = theProps;
		stage = document.getElementById('cuttr-stage');
		registered = null;
		var lines = source.split('\n').length;
		try {
			var make = new Function(
				'React', 'h', 'Fragment', 'component', 'useCurrentFrame', 'useVideoConfig',
				'useProps', 'Sequence', 'interpolate', 'spring', 'Easing', 'random',
				source + '\n//# sourceURL=' + name);
			make(React, h, React.Fragment, component, useCurrentFrame, useVideoConfig,
			     useProps, Sequence, interpolate, spring, Easing, random);
		} catch (e) {
			return trouble(e, lines);
		}
		if (typeof registered !== 'function') {
			return {message: 'this file never called component(…), so there is nothing '
				+ 'to draw. End it with component(YourFunction).', line: null};
		}
		global.__cuttrLines = lines;
		return null;
	}

	/// Draws frame `n`. Synchronous on purpose: `ReactDOM.render` in its legacy
	/// form renders on the calling turn, so by the time this returns the DOM is
	/// the frame and the snapshot cannot catch a half-built tree. The scheduler
	/// that would otherwise decide when to finish the work is the one thing in
	/// React that reads a clock.
	function draw(n) {
		try {
			ReactDOM.render(
				h(FrameContext.Provider, {value: n}, h(registered)), stage);
			// A layout, forced, for the same reason.
			void document.body.offsetHeight;
		} catch (e) {
			return trouble(e, global.__cuttrLines || 1);
		}
		return null;
	}

	global.cuttr = {mount: mount, draw: draw, missingFonts: missingFonts};
})(window);
