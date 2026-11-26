# Code d'autres projets

## ProCraft

Le lissage du tracé (`Packages/ProRangeKit/Sources/PRCore/StrokeStabilizer.swift` : filtrage du mouvement, StreamLine,
stabilisation, lissage de la pression), la mesure de la vitesse du trait (`StrokeSpeed`) et la lecture des pinceaux
Photoshop, GIMP et Krita (`Packages/ProRangeKit/Sources/PRImaging/ForeignBrushFiles.swift`) sont portés en Swift depuis
le moteur de ProCraft, `crates/engine/src/stroke.rs`, `abr.rs`, `gbr.rs` et `krita.rs` (commit `b5486737`, 25 novembre 2026) :
<https://github.com/artcraft-android/procraft>.

ProCraft est sous licence MIT ou Apache-2.0, au choix ; nous l'utilisons sous la licence MIT :

```
Copyright (c) 2026 ArtCraft Team and the ProCraft contributors.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

**Pinceaux livrés** (`App/ProCraftBrushes`) : les 38 jeux livrés avec ProCraft (598 pinceaux), écrits en `.brushset` par
ProCraft lui-même au commit `cab1062d` (job « Pinceaux ProCraft » de la CI, `tools/procraft/dump_sets.rs`). Leurs
réglages, leurs noms et leurs formes et grains (dessinés par le code de ProCraft) sont de ProCraft, sous la même
licence. Les bords humides (`StrokeMask.wetEdged`) reprennent la fonction `pooled_over` de ses shaders.

Rien d'autre n'est repris de ProCraft : ni ses icônes, ni son interface.
