// Remotion CLI config. The audio track is muxed in by the renderer — no screen recording involved.
import { Config } from '@remotion/cli/config';

Config.setVideoImageFormat('jpeg');
Config.setConcurrency(null); // auto (one render thread per core)
Config.setCodec('h264');
