import {AbsoluteFill} from 'remotion';
import {AuraMark} from '../components/AuraMark';
import {SceneFrame} from '../components/SceneFrame';
import {COLORS} from '../theme';

export const Closing = () => (
  <SceneFrame>
    <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
      <AuraMark size={250} />
      <div style={{fontSize: 38, color: COLORS.cream, marginTop: 62, fontWeight: 720}}>Park together. Match directly. Claim sovereignly.</div>
      <div style={{fontSize: 24, color: COLORS.muted, marginTop: 24}}>github.com/rainwaters11/Aura</div>
      <div style={{fontSize: 20, color: COLORS.gold, marginTop: 28, letterSpacing: 2}}>DETERMINISTIC LOCAL DEMO · UNISWAP v4 HOOK</div>
    </AbsoluteFill>
  </SceneFrame>
);
