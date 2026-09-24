import { Img } from 'react-email';

const logoStyle = {
  marginBottom: '40px',
};

export const Logo = () => {
  return (
    <Img
      src="https://raw.githubusercontent.com/Doochukbeni/lephlo-crm/lephlo/lephlo/brand/logo-150.png"
      alt="Lephlo logo"
      width="40"
      height="40"
      style={logoStyle}
    />
  );
};
