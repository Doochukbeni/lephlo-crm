import { styled } from '@linaria/react';

// Lephlo Brand Guidelines v1.0: the lockup is never retyped, recoloured or
// shown under 120px wide. Both variants render; lephlo-theme.css shows the
// reversed one in dark mode.
const LOCKUP_HEIGHT_PX = 56;

const StyledLockup = styled.img`
  display: block;
  height: ${LOCKUP_HEIGHT_PX}px;
  width: auto;
`;

export const LephloLockup = () => (
  <>
    <StyledLockup
      className="lephlo-lockup-on-light"
      src="/images/lephlo/lephlo-logo-horizontal.svg"
      alt="Lephlo"
    />
    <StyledLockup
      className="lephlo-lockup-on-dark"
      src="/images/lephlo/lephlo-logo-horizontal-white.svg"
      alt="Lephlo"
    />
  </>
);
