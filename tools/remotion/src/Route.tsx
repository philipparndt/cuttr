import { AbsoluteFill, interpolate, useCurrentFrame, useVideoConfig } from "remotion";

// A route drawing itself across a coastline, with a marker on the head of it
// and a distance that counts up.
//
// The second case that earns the machinery, and for a different reason from the
// chart. Here the *geometry* is the data: a list of coordinates, turned into an
// SVG path, whose length the browser can measure — which is what makes a route
// that draws itself possible at all. `stroke-dasharray` set to the path's own
// length and `stroke-dashoffset` walked from that length to nought is the whole
// animation, and it needs the measurement.
//
// cuttr can stroke a shape and can move one along a path, and it cannot ask how
// long an arbitrary polyline is. Nor should it: that is a browser's job, and
// this is the shape of thing browsers have been good at for twenty years.

export type RouteProps = {
	label: string;
	/** The coastline, as a fraction of the box: drawn once, never animated. */
	coast: [number, number][];
	/** The walk, in the same coordinates. */
	route: [number, number][];
	/** Real kilometres, counted up as the line is drawn. */
	kilometres: number;
	accent: string;
	ink: string;
};

export const routeDefaults: RouteProps = {
	label: "Wester Ross — Coigach to Achnahaird",
	// Irregular on purpose. Points at an even spacing read as a chart, however
	// they are joined up; a walk doubles back, hesitates at a burn and then runs
	// straight along a ridge, and it is the unevenness that says so.
	coast: [
		[0.01, 0.90], [0.06, 0.80], [0.05, 0.71], [0.11, 0.66], [0.10, 0.58],
		[0.17, 0.52], [0.16, 0.44], [0.24, 0.41], [0.29, 0.33], [0.37, 0.31],
		[0.41, 0.24], [0.49, 0.20], [0.57, 0.22], [0.62, 0.15], [0.70, 0.12],
		[0.77, 0.16], [0.83, 0.11], [0.91, 0.13], [0.99, 0.08],
	],
	route: [
		[0.10, 0.88], [0.15, 0.83], [0.19, 0.84], [0.22, 0.78], [0.27, 0.75],
		[0.31, 0.77], [0.34, 0.72], [0.33, 0.66], [0.37, 0.61], [0.43, 0.62],
		[0.47, 0.57], [0.46, 0.50], [0.51, 0.46], [0.58, 0.47], [0.62, 0.42],
		[0.66, 0.44], [0.71, 0.39], [0.70, 0.33], [0.75, 0.30], [0.81, 0.31],
		[0.86, 0.27], [0.90, 0.29], [0.93, 0.24],
	],
	kilometres: 18.4,
	accent: "#7ec8b0",
	ink: "#e9eef5",
};

/** A list of points as an SVG path, in pixels. */
const pathFor = (points: [number, number][], width: number, height: number): string =>
	points
		.map(([x, y], index) => `${index === 0 ? "M" : "L"}${x * width} ${y * height}`)
		.join(" ");

/** Where the head of the line is, `along` of the way through the points. */
const pointAt = (
	points: [number, number][],
	along: number,
	width: number,
	height: number,
): [number, number] => {
	// Walked by segment length rather than by index, so the marker moves at the
	// speed the line grows instead of hurrying through the short segments.
	const lengths = points.slice(1).map(([x, y], index) => {
		const [px, py] = points[index];
		return Math.hypot((x - px) * width, (y - py) * height);
	});
	const total = lengths.reduce((sum, length) => sum + length, 0);
	let left = total * Math.max(0, Math.min(1, along));
	for (let index = 0; index < lengths.length; index += 1) {
		if (left <= lengths[index] || index === lengths.length - 1) {
			const fraction = lengths[index] > 0 ? left / lengths[index] : 0;
			const [ax, ay] = points[index];
			const [bx, by] = points[index + 1];
			return [(ax + (bx - ax) * fraction) * width, (ay + (by - ay) * fraction) * height];
		}
		left -= lengths[index];
	}
	const [x, y] = points[points.length - 1];
	return [x * width, y * height];
};

export const Route: React.FC<RouteProps> = ({
	label,
	coast,
	route,
	kilometres,
	accent,
	ink,
}) => {
	const frame = useCurrentFrame();
	const { width, height } = useVideoConfig();

	const coastIn = interpolate(frame, [0, 34], [0, 1], {
		extrapolateLeft: "clamp",
		extrapolateRight: "clamp",
	});
	// The walk itself, from a fifth of a second in to four and a half seconds.
	const along = interpolate(frame, [18, 126], [0, 1], {
		extrapolateLeft: "clamp",
		extrapolateRight: "clamp",
	});
	const [headX, headY] = pointAt(route, along, width, height);
	// Long enough that any path is shorter than it, which is all this needs: the
	// dash is the whole line and the offset is how much of it is still to come.
	const dash = 6000;

	return (
		<AbsoluteFill style={{ fontFamily: "Helvetica Neue, Helvetica, Arial, sans-serif" }}>
			<svg width={width} height={height} style={{ position: "absolute", inset: 0 }}>
				<path
					d={pathFor(coast, width, height)}
					fill="none"
					stroke={ink}
					strokeOpacity={0.28 * coastIn}
					strokeWidth={2}
					strokeDasharray="9 7"
				/>
				{/* A wide, faint stroke under the line, so it reads over footage
				    of any brightness without a plate behind it. */}
				<path
					d={pathFor(route, width, height)}
					fill="none"
					stroke="#000000"
					strokeOpacity={0.35}
					strokeWidth={11}
					strokeLinecap="round"
					strokeLinejoin="round"
					strokeDasharray={dash}
					strokeDashoffset={dash * (1 - along)}
				/>
				<path
					d={pathFor(route, width, height)}
					fill="none"
					stroke={accent}
					strokeWidth={5}
					strokeLinecap="round"
					strokeLinejoin="round"
					strokeDasharray={dash}
					strokeDashoffset={dash * (1 - along)}
				/>
				{along > 0 ? (
					<>
						<circle cx={headX} cy={headY} r={16} fill={accent} fillOpacity={0.22} />
						<circle cx={headX} cy={headY} r={7} fill={accent} />
					</>
				) : null}
			</svg>
			<div
				style={{
					position: "absolute",
					left: 52,
					top: 44,
					color: ink,
					opacity: coastIn,
				}}
			>
				<div style={{ fontSize: 32, fontWeight: 600, letterSpacing: -0.4 }}>{label}</div>
				<div style={{ fontSize: 44, fontWeight: 300, marginTop: 6, color: accent }}>
					{(kilometres * along).toFixed(1)} km
				</div>
			</div>
		</AbsoluteFill>
	);
};
