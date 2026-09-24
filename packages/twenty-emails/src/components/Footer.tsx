import { type I18n } from '@lingui/core';
import { Container } from 'react-email';
import { Link } from 'src/components/Link';
import { ShadowText } from 'src/components/ShadowText';

const footerContainerStyle = {
  marginTop: '12px',
};

type FooterProps = {
  i18n: I18n;
};

// Lephlo: replaces Twenty's marketing links and company address.
export const Footer = ({ i18n }: FooterProps) => {
  return (
    <Container style={footerContainerStyle}>
      <ShadowText>
        <>
          {i18n._('Sent from your Lephlo workspace · Powered by Twenty')}
          <br />
          <Link
            href="https://github.com/Doochukbeni/lephlo-crm"
            value={i18n._('Source code')}
            aria-label={i18n._('View the source code of this workspace')}
          />
        </>
      </ShadowText>
    </Container>
  );
};
