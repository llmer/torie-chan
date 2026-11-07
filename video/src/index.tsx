import React from 'react';
import {Composition, registerRoot} from 'remotion';
import {Film} from './Film';
import timeline from './timeline.json';

const Root: React.FC = () => <Composition id="TorieChanFilm" component={Film}
  durationInFrames={timeline.durationInFrames} fps={timeline.fps} width={timeline.width} height={timeline.height} />;
registerRoot(Root);
