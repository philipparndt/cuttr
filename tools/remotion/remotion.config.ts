import { Config } from "@remotion/cli/config";

// PNG, because a sequence laid over a shot needs an alpha channel and PNG is
// the only image format here that has one. JPEG would arrive as a white
// rectangle with a chart in it.
//
// Everything else is on the command line in `render.sh`, deliberately: the
// script is the thing somebody reads to find out what was run, and a setting
// hidden in a config file is a setting nobody can see in the terminal.
Config.setVideoImageFormat("png");
