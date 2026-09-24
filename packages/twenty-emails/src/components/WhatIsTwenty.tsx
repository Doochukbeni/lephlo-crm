import { type I18n } from '@lingui/core';
import { MainText } from 'src/components/MainText';
import { SubTitle } from 'src/components/SubTitle';

type WhatIsTwentyProps = {
  i18n: I18n;
};

export const WhatIsTwenty = ({ i18n }: WhatIsTwentyProps) => {
  return (
    <>
      <SubTitle value={i18n._('What is Lephlo?')} />
      <MainText>
        {i18n._(
          "It's our workspace for clients, proposals, projects and invoices.",
        )}
      </MainText>
    </>
  );
};
