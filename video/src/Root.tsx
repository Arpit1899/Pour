import { cancelRender, Composition, continueRender, delayRender, staticFile } from 'remotion';
import { PourVideo } from './PourVideo';
import { DURATION, FPS, HEIGHT, WIDTH } from './theme';

// Apple's system fonts, copied from /System/Library/Fonts by `npm run fonts`
// and never committed.
const fonts = [
  { family: 'SF Pro', file: 'fonts/SFNS.ttf' },
  { family: 'New York', file: 'fonts/NewYork.ttf' },
];

const handle = delayRender('Loading fonts');
Promise.all(
  fonts.map(async ({ family, file }) => {
    const face = new FontFace(family, `url(${staticFile(file)})`, { weight: '1 1000' });
    document.fonts.add(await face.load());
  }),
)
  .then(() => continueRender(handle))
  .catch((error) => cancelRender(error));

export const Root: React.FC = () => (
  <Composition
    id="Pour"
    component={PourVideo}
    durationInFrames={DURATION}
    fps={FPS}
    width={WIDTH}
    height={HEIGHT}
  />
);
