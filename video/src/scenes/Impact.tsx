import {interpolate, useCurrentFrame} from 'remotion';
import {SceneFrame} from '../components/SceneFrame';
import {COLORS} from '../theme';

export const Impact = () => {
  const frame = useCurrentFrame();
  const matched = interpolate(frame, [0, 240], [0, 78], {extrapolateRight: 'clamp'});
  return (
    <SceneFrame eyebrow="User benefit" title="Match what fits. Move only what remains." subtitle="Aura turns compatible intent into direct volume before the pool absorbs the difference.">
      <div style={{position: 'absolute', left: 170, right: 170, top: 545}}>
        <div style={{display: 'flex', justifyContent: 'space-between', fontSize: 26, fontWeight: 720}}><span>Compatible flow matched directly</span><span>{Math.round(matched)}%</span></div>
        <div style={{height: 46, borderRadius: 999, background: '#17312e', overflow: 'hidden', marginTop: 22}}>
          <div style={{height: '100%', width: `${matched}%`, borderRadius: 999, background: `linear-gradient(90deg, ${COLORS.emerald}, ${COLORS.aqua})`, boxShadow: `0 0 50px ${COLORS.emerald}88`}} />
        </div>
        <div style={{display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 26, marginTop: 72}}>
          {['Less unnecessary curve movement', 'One uniform clearing price', 'Sovereign claims and recovery'].map((item) => (
            <div key={item} style={{padding: 30, borderRadius: 24, border: `1px solid ${COLORS.emerald}44`, background: '#0b201dcc', fontSize: 26, lineHeight: 1.35}}>{item}</div>
          ))}
        </div>
      </div>
    </SceneFrame>
  );
};
