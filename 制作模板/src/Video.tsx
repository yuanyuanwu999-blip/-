import {Audio, Video} from "@remotion/media";
import {AbsoluteFill, interpolate, Sequence, staticFile, useCurrentFrame} from "remotion";
import config from "./generated-config.json";
import captions from "../public/generated/captions.json";

type CaptionItem = {text: string; startMs: number; endMs: number};
const runtimeConfig: any = config;
const captionItems = captions as CaptionItem[];

export const BatchVideo: React.FC = () => {
  const frame = useCurrentFrame();
  const timeMs = frame / runtimeConfig.fps * 1000;
  const videoPlaybackRate = runtimeConfig.videoPlaybackRate ?? 1;
  const voiceoverPlaybackRate = runtimeConfig.voiceoverPlaybackRate ?? 1;
  const totalFrames = Math.round(runtimeConfig.totalSeconds * runtimeConfig.fps);
  const transitionFrames = Math.max(0, Math.round((runtimeConfig.timeline?.transitionSeconds ?? 0) * runtimeConfig.fps));
  const aFrames = Math.round((runtimeConfig.timeline?.aSeconds ?? runtimeConfig.segments.a.durationSeconds / videoPlaybackRate) * runtimeConfig.fps);
  const bFrom = Math.max(0, aFrames - transitionFrames);
  const bFrames = totalFrames - bFrom;
  const aOpacity = transitionFrames > 0 ? interpolate(frame, [bFrom, aFrames], [1, 0], {extrapolateLeft: "clamp", extrapolateRight: "clamp"}) : 1;
  const bOpacity = transitionFrames > 0 ? interpolate(frame, [bFrom, bFrom + transitionFrames], [0, 1], {extrapolateLeft: "clamp", extrapolateRight: "clamp"}) : 1;
  const currentCaption = captionItems.find((caption) => timeMs >= caption.startMs && timeMs < caption.endMs);

  return (
    <AbsoluteFill style={{backgroundColor: "#000"}}>
      <Sequence durationInFrames={aFrames}>
        <Video
          src={staticFile(runtimeConfig.assets.a)}
          muted
          playbackRate={videoPlaybackRate}
          objectFit="cover"
          style={{width: "100%", height: "100%", opacity: aOpacity}}
        />
      </Sequence>
      <Sequence from={bFrom} durationInFrames={bFrames}>
        <Video
          src={staticFile(runtimeConfig.assets.b)}
          muted
          playbackRate={videoPlaybackRate}
          objectFit="cover"
          style={{width: "100%", height: "100%", opacity: bOpacity}}
        />
      </Sequence>

      {runtimeConfig.voiceoverSegments.map((segment: {asset: string; startMs: number}) => (
        <Sequence key={segment.asset} from={Math.round(segment.startMs / 1000 * runtimeConfig.fps)}>
          <Audio src={staticFile(segment.asset)} volume={runtimeConfig.audio.voiceoverVolume} playbackRate={voiceoverPlaybackRate} />
        </Sequence>
      ))}

      {runtimeConfig.assets.environmentA ? (
        <Sequence durationInFrames={aFrames}>
          <Audio src={staticFile(runtimeConfig.assets.environmentA)} volume={(localFrame) => (runtimeConfig.sourceAudioMode ? 1 : runtimeConfig.audio.environmentVolume) * (transitionFrames > 0 ? interpolate(localFrame, [aFrames - transitionFrames, aFrames], [1, 0], {extrapolateLeft: "clamp", extrapolateRight: "clamp"}) : 1)} playbackRate={videoPlaybackRate} />
        </Sequence>
      ) : null}
      {runtimeConfig.assets.environmentB ? (
        <Sequence from={bFrom} durationInFrames={bFrames}>
          <Audio src={staticFile(runtimeConfig.assets.environmentB)} volume={(localFrame) => (runtimeConfig.sourceAudioMode ? 1 : runtimeConfig.audio.environmentVolume) * (transitionFrames > 0 ? interpolate(localFrame, [0, transitionFrames], [0, 1], {extrapolateLeft: "clamp", extrapolateRight: "clamp"}) : 1)} playbackRate={videoPlaybackRate} />
        </Sequence>
      ) : null}

      {runtimeConfig.assets.backgroundMusic ? (
        <Audio
          src={staticFile(runtimeConfig.assets.backgroundMusic)}
          volume={(f) => {
            // Apply the audible music floor to older saved batch configurations too.
            const base = Math.max(0.40, Number(runtimeConfig.audio.backgroundMusicVolume ?? 0.40));
            const speaking = captionItems.some((caption) => f / runtimeConfig.fps * 1000 >= caption.startMs && f / runtimeConfig.fps * 1000 < caption.endMs);
            return speaking ? base * 0.75 : base;
          }}
        />
      ) : null}

      {currentCaption ? (
        <div style={{
          position: "absolute",
          left: 70,
          right: 70,
          bottom: runtimeConfig.captions.bottom,
          color: runtimeConfig.captions.color,
          fontFamily: runtimeConfig.captions.fontFamily,
          fontSize: runtimeConfig.captions.fontSize,
          fontWeight: runtimeConfig.captions.fontWeight ?? 800,
          lineHeight: 1.35,
          textAlign: "center",
          whiteSpace: "pre-line",
          letterSpacing: 1,
          WebkitTextStroke: `${runtimeConfig.captions.strokeWidth ?? 2}px rgba(10,10,10,0.95)`,
          paintOrder: "stroke fill",
          textShadow: "0 3px 7px rgba(0,0,0,0.65)",
        }}>{currentCaption.text}</div>
      ) : null}
    </AbsoluteFill>
  );
};
