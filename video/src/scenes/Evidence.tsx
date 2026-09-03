import {interpolate, useCurrentFrame} from 'remotion';
import {SceneFrame} from '../components/SceneFrame';
import {COLORS} from '../theme';

const evidence = [
  ['211', 'Foundry tests passed'],
  ['0', 'test failures'],
  ['21,716', 'AuraHook runtime bytes'],
  ['2,860', 'bytes below EIP-170'],
];

export const Evidence = () => {
  const frame = useCurrentFrame();
  return (
    <SceneFrame eyebrow="Verified locally" title="Proof before promises." subtitle="Unit, fuzz, integration, regression, and invariant coverage protect the bounded settlement path.">
      <div style={{position: 'absolute', left: 116, right: 116, top: 530, display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 22}}>
        {evidence.map(([value, label], index) => {
          const opacity = interpolate(frame, [index * 12, index * 12 + 20], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
          return (
            <div key={label} style={{padding: '45px 30px', borderRadius: 28, background: '#0c211fdd', border: `1px solid ${COLORS.gold}44`, opacity}}>
              <div style={{fontSize: 57, fontWeight: 820, color: index === 1 ? COLORS.emerald : COLORS.gold}}>{value}</div>
              <div style={{fontSize: 23, color: COLORS.muted, marginTop: 18, lineHeight: 1.35}}>{label}</div>
            </div>
          );
        })}
      </div>
      <div style={{position: 'absolute', left: 116, top: 870, color: COLORS.muted, fontSize: 20}}>Use the final exact-head CI totals if they change before submission.</div>
    </SceneFrame>
  );
};
