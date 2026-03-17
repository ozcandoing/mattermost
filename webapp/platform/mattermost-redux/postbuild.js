// Cross-platform replacement for postbuild.sh
// Copies TypeScript declaration files that are not emitted by tsc.
'use strict';

const fs = require('fs');
const path = require('path');

const copies = [
    [
        '../../channels/src/packages/mattermost-redux/src/selectors/create_selector/index.d.ts',
        'lib/selectors/create_selector/index.d.ts',
    ],
    [
        '../../channels/src/packages/mattermost-redux/src/types/extend_redux.d.ts',
        'lib/types/extend_redux.d.ts',
    ],
    [
        '../../channels/src/packages/mattermost-redux/src/types/extend_react_redux.d.ts',
        'lib/types/extend_react_redux.d.ts',
    ],
];

for (const [src, dest] of copies) {
    const srcPath  = path.resolve(__dirname, src);
    const destPath = path.resolve(__dirname, dest);
    fs.mkdirSync(path.dirname(destPath), {recursive: true});
    fs.copyFileSync(srcPath, destPath);
    console.log(`Copied: ${src} -> ${dest}`);
}
