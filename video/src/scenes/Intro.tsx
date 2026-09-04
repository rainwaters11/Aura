import {AbsoluteFill} from 'remotion';
import {AuraMark} from '../components/AuraMark';
import {SceneFrame} from '../components/SceneFrame';

export const Intro = () => (
  <SceneFrame>
    <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
      <AuraMark size={330} />
    </AbsoluteFill>
  </SceneFrame>
);
