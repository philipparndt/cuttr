# What is in this folder, and under what terms

These three files are the whole of a `component:` part's runtime. They are
loaded into a `WKWebView` from the app bundle, inline, and nothing is ever
fetched — which is the point of them being here rather than in a `package.json`.

| file | version | licence |
|---|---|---|
| `react.min.js` | React 18.3.1, `umd/react.production.min.js` | MIT |
| `react-dom.min.js` | React DOM 18.3.1, `umd/react-dom.production.min.js` | MIT |
| `cuttr-component.js` | ours | the same as the rest of this program |

10.7 kB, 131.8 kB and about 12 kB. The two React files carry their licence
header in the file itself, which is where a licence should be; it is reproduced
below so that this table is checkable without opening a minified bundle.

## Why there is no transpiler here

`@babel/standalone` — the browser build that would let a component be written in
JSX — is 3.07 MB. That is twenty-one times the whole of React, in the app, to
support one piece of syntax. It was left out for three reasons and the size is
the least of them.

A compiler in the bundle is a compiler *version* that every baked frame depends
on and that appears nowhere a person can see. The complaint `docs/remotion.md`
makes about the real Remotion is precisely this — that a lockfile becomes part
of the project — and shipping Babel reproduces it in miniature.

JSX compiles to `React.createElement`, which the runtime hands the component as
`h`. For the content this feature is actually good at — a chart, a leaderboard,
a table, anything data-driven — the component is building arrays of elements
with `.map`, and there `h('div', {…}, rows)` is no less readable than the JSX it
would compile to. The difference only bites on deeply nested static markup,
which is the case a `scenes:` block already covers better.

And a transpile is a second class of failure to report, with its own line
numbers in a file nobody wrote.

Somebody who wants JSX, TypeScript and the real `@remotion/*` packages should
use the external Remotion path, which `docs/remotion.md` describes and which is
not going away. That is a toolchain, and JSX is a thing toolchains are for.

## React's licence

    MIT License

    Copyright (c) Facebook, Inc. and its affiliates.

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in
    all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
    FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
    DEALINGS IN THE SOFTWARE.
