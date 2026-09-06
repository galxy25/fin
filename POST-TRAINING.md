# Post-training sequence (fin-foreman-e4b-mlx, run 1)

Run these IN ORDER from this worktree (`fin-wt-gate`, on main). It exists because
the primary checkout sits on `imac-site`, whose `router.md` differs from the one
the training corpus was built from.

0. CONFIRM TRAINING IS DONE — the sweep refuses otherwise, but check anyway:
     tail -3 ~/forges/levi/fin/models/candidates/fin-foreman-e4b-mlx/train.log
   Expect "Saved final weights". Confirm no `mlx_lm lora` process remains.

1. BRING THE BRAIN BACK for the champion arm (LM Studio serves the GGUF champion):
     open -a "LM Studio"; lms server start; lms load google/gemma-4-e4b --identifier gemma-4-e4b
   The champion MUST be re-recorded: the stored 36/51 was measured with the
   round-0 prompt, and the shipped round-3 prompt scores 49/51 on the SAME model.
   Promoting against the stored number would flatter any candidate into a false win.

2. RUN THE SWEEP (scores several checkpoints, not just the last):
     bash scripts/model-factory/gate_sweep.sh 1000 2250 3500 final
   It refuses if a fine-tune is running, if under 10 GB is free, or if router.md
   is not the training prompt. Each fused model is ~6 GB and is deleted after
   scoring. Results: models/gate-sweep/results.tsv, provenance.txt.

3. READ THE RESULT HONESTLY. Promotion needs all 26 core scenarios AND strictly
   beating the re-recorded champion on core+hard. Ties do not promote. Expect the
   best checkpoint may NOT be the last — train loss hit 0.000 by ~iter 2900 on a
   corpus synthesized from template families, and validation has sat near 0.01
   since iter 1000, so later checkpoints may only be memorizing harder.

4. WHATEVER THE VERDICT, restore the daemon's brain:
     lms load google/gemma-4-12b-qat
   and leave the Funnel shim untouched.

5. THEN, and only then, consider merging `imac-site` (which changes router.md).
   After that merge a champion re-score is owed, and a decision about whether the
   training corpus should be regenerated against the new prompt.

6. The bits experiment (scripts/model-factory/run_bits_experiment.sh on branch
   bits-curriculum) can run once the GPU is free — it is the first thing that
   would produce a real bits number. Nothing in it has ever been run.
