// A year of walks, as a chart.
//
// Twelve bars, twelve values, twelve month labels, a scale up the left with six
// gridlines and a number on each, a running total that counts up, and a
// sentence naming the best month. Fifty-odd things on the frame, every one of
// them positioned from the data by arithmetic — which is what makes this a
// component and not a scene.
//
// cuttr hands this function a frame number and takes a photograph of what it
// returns. There is no clock in here, and there cannot be: `Date.now()` is
// frozen at the epoch and `Math.random()` throws, so the same file gives the
// same twelve bars on every render.

// The data. In the file, on purpose. It could be props, but a project file is
// not where twelve numbers with names on want to live, and nothing may be
// fetched — so this is the honest place for it.
const MONTHS = [
	['Jan', 41], ['Feb', 38], ['Mar', 62], ['Apr', 74],
	['May', 96], ['Jun', 88], ['Jul', 121], ['Aug', 104],
	['Sep', 79], ['Oct', 58], ['Nov', 44], ['Dec', 51],
];

function Walks() {
	const frame = useCurrentFrame();
	const { width, height, fps } = useVideoConfig();
	const { unit, accent } = useProps();

	// Everything below is in pixels of the frame cuttr asked for, so the same
	// file draws correctly at 1920x1080 and at 1280x720.
	const pad = { left: width * 0.11, right: width * 0.05,
	              top: height * 0.26, bottom: height * 0.16 };
	const plot = {
		width: width - pad.left - pad.right,
		height: height - pad.top - pad.bottom,
	};
	const total = MONTHS.reduce((sum, m) => sum + m[1], 0);
	const most = Math.max.apply(null, MONTHS.map((m) => m[1]));
	// Rounded up to the next twenty-five, so the five gridlines below land on
	// numbers somebody would have chosen rather than on 31.25.
	const ceiling = Math.ceil(most / 25) * 25;
	const divisions = 5;
	const best = MONTHS.reduce((a, b) => (b[1] > a[1] ? b : a));

	// A bar starts when the one before it is a third of the way up, which is
	// what makes twelve bars read as a sweep rather than as twelve bars.
	const stagger = 2;
	const grow = 14;

	const gridlines = [];
	for (let step = 0; step <= divisions; step++) {
		const value = (ceiling / divisions) * step;
		const y = pad.top + plot.height - (value / ceiling) * plot.height;
		const drawn = interpolate(frame, [0, 10], [0, 1],
			{ extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic) });
		gridlines.push(h('div', {
			key: 'line' + step,
			style: {
				position: 'absolute', left: pad.left + 'px', top: y + 'px',
				width: plot.width * drawn + 'px', height: '1px',
				background: step === 0 ? 'rgba(255,255,255,0.45)' : 'rgba(255,255,255,0.10)',
			},
		}));
		gridlines.push(h('div', {
			key: 'tick' + step,
			style: {
				position: 'absolute', right: (width - pad.left + width * 0.014) + 'px',
				top: (y - height * 0.017) + 'px',
				font: '500 ' + Math.round(height * 0.024) + 'px "Helvetica Neue"',
				color: 'rgba(255,255,255,0.42)', textAlign: 'right',
				opacity: drawn,
			},
		}, String(value)));
	}

	const gap = plot.width * 0.028;
	const barWidth = (plot.width - gap * (MONTHS.length - 1)) / MONTHS.length;

	const bars = MONTHS.map(([name, value], index) => {
		const begins = index * stagger;
		// `spring` rather than `interpolate`, because a bar that overshoots by a
		// hair and settles reads as a thing arriving and a linear one reads as a
		// thing being drawn.
		const rise = spring({
			frame: frame - begins, fps: fps,
			config: { damping: 14, stiffness: 90, mass: 0.8 },
		});
		const tall = Math.max(0, (value / ceiling) * plot.height * rise);
		const left = pad.left + index * (barWidth + gap);
		const isBest = name === best[0];
		const label = interpolate(frame - begins - grow, [0, 8], [0, 1],
			{ extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });

		return h('div', { key: name },
			h('div', {
				style: {
					position: 'absolute', left: left + 'px',
					top: (pad.top + plot.height - tall) + 'px',
					width: barWidth + 'px', height: tall + 'px',
					background: isBest ? accent : 'rgba(255,255,255,0.22)',
					borderRadius: (barWidth * 0.14) + 'px ' + (barWidth * 0.14) + 'px 0 0',
				},
			}),
			// The number on top of the bar, which arrives once the bar has.
			h('div', {
				style: {
					position: 'absolute', left: left + 'px',
					top: (pad.top + plot.height - tall - height * 0.048) + 'px',
					width: barWidth + 'px', textAlign: 'center',
					font: '600 ' + Math.round(height * 0.026) + 'px "Helvetica Neue"',
					color: isBest ? accent : 'rgba(255,255,255,0.70)',
					opacity: label,
				},
			}, String(value)),
			h('div', {
				style: {
					position: 'absolute', left: left + 'px',
					top: (pad.top + plot.height + height * 0.022) + 'px',
					width: barWidth + 'px', textAlign: 'center',
					font: '500 ' + Math.round(height * 0.024) + 'px "Helvetica Neue"',
					color: 'rgba(255,255,255,0.50)',
				},
			}, name));
	});

	// The total, counting up over the first two seconds and then holding.
	const counted = Math.round(interpolate(frame, [0, fps * 2], [0, total],
		{ extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic) }));

	return h('div', { style: { position: 'absolute', left: 0, top: 0,
	                           width: '100%', height: '100%' } },
		h('div', {
			style: {
				position: 'absolute', left: pad.left + 'px', top: (height * 0.10) + 'px',
				font: '700 ' + Math.round(height * 0.062) + 'px "Helvetica Neue"',
				letterSpacing: '-0.02em', color: '#ffffff',
			},
		}, counted + ' ' + unit),
		h('div', {
			style: {
				position: 'absolute', left: pad.left + 'px', top: (height * 0.185) + 'px',
				font: '500 ' + Math.round(height * 0.028) + 'px "Helvetica Neue"',
				color: 'rgba(255,255,255,0.55)',
			},
		}, 'walked in the year — best month ' + best[0] + ', ' + best[1] + ' ' + unit),
		gridlines,
		bars);
}

// How cuttr is told which function this file is. Remotion spells this
// `registerRoot`; there is one component here, so it is one word.
component(Walks);
