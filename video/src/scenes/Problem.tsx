import {interpolate, useCurrentFrame} from 'remotion';
import {SceneFrame} from '../components/SceneFrame';
import {COLORS} from '../theme';

const Flow = ({top, color, reverse = false}: {top: number; color: string; reverse?: boolean}) => {
  const frame = useCurrentFrame();
  const x = interpolate(frame % 150, [0, 150], reverse ? [1600, 100] : [100, 1600]);
  return (
    <>
      <div style={{position: 'absolute', top, left: 160, right: 160, height: 5, background: `linear-gradient(90deg, transparent, ${color}, transparent)`, opacity: 0.55}} />
      <div style={{position: 'absolute', top: top - 18, left: x, width: 42, height: 42, borderRadius: '50%', background: color, boxShadow: `0 0 40px ${color}`}} />
    </>
  );
};

export const Problem = () => (
  <SceneFrame
    eyebrow="The problem"
    title="Compatible intent still trades alone."
    subtitle="When every order touches the pool first, users can consume liquidity and create avoidable price impact—even when opposite demand already exists."
  >
    <div style={{position: 'absolute', left: 120, right: 120, top: 520, bottom: 160, borderRadius: 44, border: `1px solid ${COLORS.aqua}33`, background: '#071b1988'}}>
      <Flow top={95} color={COLORS.violet} />
      <Flow top={220} color={COLORS.aqua} reverse />
      <div style={{position: 'absolute', left: '50%', top: '50%', transform: 'translate(-50%, -50%)', width: 210, height: 210, borderRadius: '50%', border: `14px solid ${COLORS.danger}`, boxShadow: `0 0 80px ${COLORS.danger}55`, display: 'grid', placeItems: 'center', color: COLORS.cream, fontSize: 27, fontWeight: 760, textAlign: 'center'}}>
        POOL<br />FIRST
      </div>
    </div>
  </SceneFrame>
);
