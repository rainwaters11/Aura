import type {ComponentType} from 'react';
import {Composition} from 'remotion';
import {AuraDemo} from './AuraDemo';
import {Architecture} from './scenes/Architecture';
import {Closing} from './scenes/Closing';
import {Evidence} from './scenes/Evidence';
import {Impact} from './scenes/Impact';
import {Intro} from './scenes/Intro';
import {Problem} from './scenes/Problem';
import {DURATIONS, FPS, HEIGHT, TOTAL_FRAMES, WIDTH} from './theme';

const composition = (id: string, component: ComponentType, durationInFrames: number) => (
  <Composition id={id} component={component} durationInFrames={durationInFrames} fps={FPS} width={WIDTH} height={HEIGHT} />
);

export const RemotionRoot = () => (
  <>
    <Composition
      id="AuraDemo"
      component={AuraDemo}
      durationInFrames={TOTAL_FRAMES}
      fps={FPS}
      width={WIDTH}
      height={HEIGHT}
      defaultProps={{}}
    />
    {composition('AuraIntro', Intro, DURATIONS.intro)}
    {composition('AuraProblem', Problem, DURATIONS.problem)}
    {composition('AuraArchitecture', Architecture, DURATIONS.architecture)}
    {composition('AuraEvidence', Evidence, DURATIONS.evidence)}
    {composition('AuraImpact', Impact, DURATIONS.impact)}
    {composition('AuraClosing', Closing, DURATIONS.closing)}
  </>
);
