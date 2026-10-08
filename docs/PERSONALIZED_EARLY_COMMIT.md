# Personalized early-commit confidence

Synced from TigerClaw main on 2026-09-18.

The Lua sentence engine now separates model confidence from personalized early-commit confidence:

- `base_share`: pure model confidence; authoritative for strong evidence, truncated-strong and boundary closure.
- `share`: base confidence plus bounded personalization; used only for ordinary multi-generation evidence.

Supplement phrases add `min(0.75, supplement_score * 0.05)` to early-commit log confidence. Learning uses persistent manual-correction levels: exact-context scores are `9, 11, 13, ...`, while cross-context scores are `6, 8, 10, ...`. Early-commit maturity maps exact scores `9 -> 0`, `11 -> 0.5`, and `13+ -> 1.0`. Learning contribution is capped at 0.75 and total personalization at 0.80.

The first correction changes ranking but adds no early confidence. Only a later explicit correction away from the then-current first choice can raise the level; normal acceptance of the learned top candidate and automatic early commit never reinforce it. Learning has no time decay. Learning plus beam truncation is still blocked from automatic commit, and empty-code commit remains model-only.

Thresholds match TigerClaw: ordinary `0.99`, strong `0.999`, boundary closure/empty-code strong `0.99999`, three ordinary generations or two strong generations, and retain three raw keys. Truncated evidence is retained and can only commit through model-only strong evidence.
