import {Composition} from "remotion";
import {BatchVideo} from "./Video";
import config from "./generated-config.json";
import "./index.css";

export const RemotionRoot: React.FC = () => (
  <Composition
    id={config.compositionId}
    component={BatchVideo}
    durationInFrames={Math.round(config.totalSeconds * config.fps)}
    fps={config.fps}
    width={config.width}
    height={config.height}
    defaultProps={{}}
  />
);
