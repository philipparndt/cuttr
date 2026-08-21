import { Composition } from "remotion";
import { Chart, chartDefaults } from "./Chart";
import { Route, routeDefaults } from "./Route";

// Sizes are the size the frames are *drawn* at, not the size of the programme.
//
// A sequence is scaled to `size:` in the project file, and scaling a picture
// down is free while scaling one up is a soft picture — so the rule is: render
// at about the number of pixels the overlay will occupy. `chart` is laid over a
// 1920×1080 programme at `size: 0.62`, which is 670 pixels tall, so 1200×680 is
// the right order of magnitude and 3840×2160 would be forty times the disk for
// nothing.
//
// Durations are the length of the animation, in its own frames. What happens
// when the sequence and the span do not agree is `ends:` in the project file,
// and the answer is never "stretch" — see `docs/remotion.md`.
export const Root: React.FC = () => {
	return (
		<>
			<Composition
				id="chart"
				component={Chart}
				width={1200}
				height={680}
				fps={30}
				durationInFrames={135}
				defaultProps={chartDefaults}
			/>
			<Composition
				id="route"
				component={Route}
				width={1200}
				height={680}
				fps={30}
				durationInFrames={165}
				defaultProps={routeDefaults}
			/>
		</>
	);
};
