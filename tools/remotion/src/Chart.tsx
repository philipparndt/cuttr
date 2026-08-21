import { AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";

// An animated bar chart, drawn from a list of numbers.
//
// This is the case Remotion is genuinely better at than anything cuttr's scene
// vocabulary can say, and it is worth being precise about why. A scene can draw
// a bar: `bar:` is a part kind, `progress` is a key, and one bar growing over
// three seconds is four lines of YAML. What a scene cannot do is *lay out* a
// chart — put twelve bars in a row with even gaps whatever twelve turns out to
// be, scale them all against whichever is the largest, print each one's value
// over its own top, put a month under it, and draw gridlines at round numbers
// worked out from the data. Every one of those is arithmetic over the data, and
// a project file that held the results of it would be holding a layout instead
// of describing one: change one number and every other number in the file is
// wrong.
//
// So: the layout is code, the code runs once, and cuttr composites the pixels.

export type ChartProps = {
	title: string;
	unit: string;
	/** Whatever length it is. The layout is worked out from it. */
	bars: { label: string; value: number }[];
	/** Foil for the tallest bar, so the point of the chart reads at a glance. */
	accent: string;
	ink: string;
};

export const chartDefaults: ChartProps = {
	title: "Kilometres walked",
	unit: "km",
	bars: [
		{ label: "Jan", value: 41 },
		{ label: "Feb", value: 38 },
		{ label: "Mar", value: 66 },
		{ label: "Apr", value: 92 },
		{ label: "May", value: 118 },
		{ label: "Jun", value: 137 },
		{ label: "Jul", value: 161 },
		{ label: "Aug", value: 154 },
		{ label: "Sep", value: 121 },
		{ label: "Oct", value: 84 },
		{ label: "Nov", value: 52 },
		{ label: "Dec", value: 47 },
	],
	accent: "#f0a35e",
	ink: "#e9eef5",
};

/** A round number at or above the largest bar, so the top gridline is readable. */
const ceilingFor = (largest: number): number => {
	const magnitude = Math.pow(10, Math.floor(Math.log10(largest)));
	const step = magnitude / 2;
	return Math.ceil(largest / step) * step;
};

export const Chart: React.FC<ChartProps> = ({ title, unit, bars, accent, ink }) => {
	const frame = useCurrentFrame();
	const { fps, width, height } = useVideoConfig();

	const padding = { left: 96, right: 40, top: 108, bottom: 76 };
	const plot = {
		x: padding.left,
		y: padding.top,
		width: width - padding.left - padding.right,
		height: height - padding.top - padding.bottom,
	};

	const largest = Math.max(...bars.map((bar) => bar.value));
	const ceiling = ceilingFor(largest);
	const gridlines = 4;
	const gap = plot.width / bars.length;
	const barWidth = Math.min(56, gap * 0.56);

	// The title wipes on, then the axis draws itself, then the bars grow one
	// after another. Timed in frames because a composition's clock is frames.
	const titleIn = spring({ frame, fps, config: { damping: 200 }, durationInFrames: 18 });
	const axisIn = interpolate(frame, [8, 26], [0, 1], {
		extrapolateLeft: "clamp",
		extrapolateRight: "clamp",
	});

	return (
		// No background at all. The frames are composited over the programme, so
		// a background here would be a rectangle hiding the shot — which is the
		// same mistake `examples/README.md` warns about for a scene's full-frame
		// background, arriving from a different direction.
		<AbsoluteFill style={{ fontFamily: "Helvetica Neue, Helvetica, Arial, sans-serif" }}>
			<div
				style={{
					position: "absolute",
					left: padding.left,
					top: 40,
					fontSize: 40,
					fontWeight: 600,
					letterSpacing: -0.5,
					color: ink,
					opacity: titleIn,
					transform: `translateY(${(1 - titleIn) * 14}px)`,
				}}
			>
				{title}
			</div>
			<div
				style={{
					position: "absolute",
					left: padding.left,
					top: 90,
					fontSize: 18,
					color: ink,
					opacity: titleIn * 0.55,
				}}
			>
				{unit}
			</div>

			<svg width={width} height={height} style={{ position: "absolute", inset: 0 }}>
				{/* The gridlines, at round numbers worked out from the data. */}
				{Array.from({ length: gridlines + 1 }).map((_, step) => {
					const value = (ceiling / gridlines) * step;
					const y = plot.y + plot.height - (value / ceiling) * plot.height;
					return (
						<g key={step} opacity={axisIn}>
							<line
								x1={plot.x}
								x2={plot.x + plot.width * axisIn}
								y1={y}
								y2={y}
								stroke={ink}
								strokeOpacity={step === 0 ? 0.5 : 0.14}
								strokeWidth={step === 0 ? 2 : 1}
							/>
							<text
								x={plot.x - 16}
								y={y + 6}
								textAnchor="end"
								fill={ink}
								fillOpacity={0.5}
								fontSize={17}
							>
								{Math.round(value)}
							</text>
						</g>
					);
				})}

				{bars.map((bar, index) => {
					// Each bar starts a frame and a half after the one before, so
					// the row reads left to right rather than all at once.
					const grown = spring({
						frame: frame - 22 - index * 1.5,
						fps,
						config: { damping: 14, mass: 0.5 },
					});
					const full = (bar.value / ceiling) * plot.height;
					const tall = full * grown;
					const x = plot.x + gap * index + (gap - barWidth) / 2;
					const tallest = bar.value === largest;
					return (
						<g key={bar.label}>
							<rect
								x={x}
								y={plot.y + plot.height - tall}
								width={barWidth}
								height={Math.max(0, tall)}
								rx={5}
								fill={tallest ? accent : ink}
								fillOpacity={tallest ? 0.95 : 0.42}
							/>
							<text
								x={x + barWidth / 2}
								y={plot.y + plot.height - tall - 14}
								textAnchor="middle"
								fill={tallest ? accent : ink}
								fillOpacity={interpolate(grown, [0.6, 1], [0, tallest ? 1 : 0.7], {
									extrapolateLeft: "clamp",
									extrapolateRight: "clamp",
								})}
								fontSize={19}
								fontWeight={tallest ? 600 : 400}
							>
								{bar.value}
							</text>
							<text
								x={x + barWidth / 2}
								y={plot.y + plot.height + 32}
								textAnchor="middle"
								fill={ink}
								fillOpacity={0.55 * axisIn}
								fontSize={18}
							>
								{bar.label}
							</text>
						</g>
					);
				})}
			</svg>
		</AbsoluteFill>
	);
};
