import type {ReactNode} from 'react';
import {AbsoluteFill, Audio, OffthreadVideo, Sequence, staticFile} from 'remotion';
import {Architecture} from './scenes/Architecture';
import {Closing} from './scenes/Closing';
import {ConsoleSegment} from './scenes/ConsoleSegment';
import {Evidence} from './scenes/Evidence';
import {Impact} from './scenes/Impact';
import {Intro} from './scenes/Intro';
import {Problem} from './scenes/Problem';
import {DURATIONS} from './theme';

export type AuraDemoProps = {
  introClip?: string;
  problemClip?: string;
  consoleClip?: string;
  impactClip?: string;
  voiceover?: string;
};

const OptionalVideo = ({clip, fallback}: {clip?: string; fallback: ReactNode}) =>
  clip ? <OffthreadVideo src={staticFile(clip)} style={{width: '100%', height: '100%', objectFit: 'cover'}} /> : <>{fallback}</>;

export const AuraDemo = ({introClip, problemClip, consoleClip, impactClip, voiceover}: AuraDemoProps) => {
  let start = 0;
  const introStart = start;
  start += DURATIONS.intro;
  const problemStart = start;
  start += DURATIONS.problem;
  const architectureStart = start;
  start += DURATIONS.architecture;
  const consoleStart = start;
  start += DURATIONS.console;
  const evidenceStart = start;
  start += DURATIONS.evidence;
  const impactStart = start;
  start += DURATIONS.impact;
  const closingStart = start;

  return (
    <AbsoluteFill>
      {voiceover ? <Audio src={staticFile(voiceover)} /> : null}
      <Sequence from={introStart} durationInFrames={DURATIONS.intro}><OptionalVideo clip={introClip} fallback={<Intro />} /></Sequence>
      <Sequence from={problemStart} durationInFrames={DURATIONS.problem}><OptionalVideo clip={problemClip} fallback={<Problem />} /></Sequence>
      <Sequence from={architectureStart} durationInFrames={DURATIONS.architecture}><Architecture /></Sequence>
      <Sequence from={consoleStart} durationInFrames={DURATIONS.console}><ConsoleSegment clip={consoleClip} /></Sequence>
      <Sequence from={evidenceStart} durationInFrames={DURATIONS.evidence}><Evidence /></Sequence>
      <Sequence from={impactStart} durationInFrames={DURATIONS.impact}><OptionalVideo clip={impactClip} fallback={<Impact />} /></Sequence>
      <Sequence from={closingStart} durationInFrames={DURATIONS.closing}><Closing /></Sequence>
    </AbsoluteFill>
  );
};
