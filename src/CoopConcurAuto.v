Require Import CoopConcur CoopConcurMonad.
Require Export Locking.
Require Export Automation.
Require Import FunctionalExtensionality.
Require Import Star.
Import Bool.

Set Implicit Arguments.

Ltac inv_opt :=
  match goal with
  | [ H: None = Some _ |- _ ] =>
    now (inversion H)
  | [ H: Some _ = None |- _ ] =>
    now (inversion H)
  | [ H: Some _ = Some _ |- _ ] =>
    inversion H; subst; clear H
  | [ H: None = None |- _ ] =>
    clear H
  end.

Ltac econtradiction H :=
  exfalso; eapply H.


(* extract the precondition of a valid statement into the hypotheses *)
Ltac intros_pre :=
  apply valid_unfold; unfold pred_in; intros;
  repeat deex.

Ltac split_ands :=
  destruct_ands; repeat (split; intros).

(* simplify the postcondition obligation to its components *)
Ltac simpl_post :=
  cbn; unfold pred_in;
  split_ands;
  repeat deex.

(* Captures a program in a type so the hypotheses can give the program that
  produced each proof obligation. *)
Inductive CurrentProg {Sigma} {T} (p: prog Sigma T) :=
| SomeProg.

Inductive PrevProg {Sigma} {T} (p: prog Sigma T) :=
| SomePrevProg.

Local Ltac set_prog p :=
  try match goal with
  | [ H: CurrentProg ?p' |- _ ] =>
    try match goal with
        | [ H': PrevProg _ |- _ ] => clear H'
        end;
    let Hprev := fresh "PostOf" in
    pose proof (SomePrevProg p') as Hprev;
    clear H
  end;
  let H := fresh "PreOf" in
  pose proof (SomeProg p) as H.

Tactic Notation "current" "prog" :=
  try match goal with
      | [ H: PrevProg ?p |- _ ] =>
        idtac "ran"; idtac p
      end;
  idtac "precondition for";
  match goal with
  | [ H: CurrentProg ?p |- _ ] => idtac p
  end.

Ltac next_control_step :=
    match goal with
    | [ |- valid _ _ _ ?p ] =>
      monad_simpl;
      eapply pimpl_ok; [ now (auto with prog) | set_prog p  ]
    end.

Ltac unfold_prog :=
  lazymatch goal with
  | [ |- valid _ _ _ (Bind ?p _) ] =>
    let program := head_symbol p in
    unfold program
  end.

Ltac valid_match_ok :=
  match goal with
  | [ |- valid _ _ _ (Bind (match ?d with | _ => _ end) _) ] =>
    case_eq d; intros;
    match goal with
    | [ |- valid _ _ _ ?p ] => set_prog p
    end
  end.

Ltac step' simplifier finisher :=
  repeat (autounfold with prog);
  next_control_step ||
                    (unfold_prog; next_control_step) ||
                    valid_match_ok;
  repeat (autounfold with prog);
  simplifier;
  finisher.

Ltac unfold_pred_applications :=
  unfold pred_in; intros; repeat deex.

Ltac step_simplifier :=
  unfold_pred_applications;
  simpl_post;
  try subst.

Ltac simpl_goal :=
  repeat match goal with
         | [ |- _ /\ _ ] => split
         | [ |- forall _, _ ] => intros
         end.

Ltac step_finisher :=
  simpl_goal;
  try solve [ pred_apply; cancel ];
  eauto.

Tactic Notation "step" := step' step_simplifier step_finisher.
Tactic Notation "step" "pre" tactic(simplifier) := step' simplifier step_finisher.
Tactic Notation "step" "pre" tactic(simplifier) "with" tactic(finisher) := step' simplifier finisher.
Tactic Notation "step" "with" tactic(finisher) := step' step_simplifier finisher.

Ltac hoare' simplifier finisher  := intros; repeat step' simplifier finisher.
Tactic Notation "hoare" := hoare' step_simplifier step_finisher.
Tactic Notation "hoare" "pre" tactic(simplifier) := hoare' simplifier step_finisher.
Tactic Notation "hoare" "pre" tactic(simplifier) "with" tactic(finisher) := hoare' simplifier finisher.
Tactic Notation "hoare" "with" tactic(finisher) := hoare' step_simplifier finisher.

Definition Read {Sigma} a : prog Sigma _ :=
  StartRead a;;
            v <- FinishRead a;
    Ret v.

Section ReadWriteTheorems.

  Hint Resolve
       diskIs_combine_same'_applied
       diskIs_combine_upd
       diskIs_same.

  Hint Resolve ptsto_valid ptsto_valid'.

  Theorem Read_ok : forall Sigma (delta: Protocol Sigma) a,
      SPEC delta, tid |-
      {{ F v,
       | PRE d m s_i s: d |= F * a |-> (v, None)
       | POST d' m' s_i' s' r: d' = d /\
                              s_i' = s_i /\
                              s' = s /\
                              m' = m /\
                              r = v
      }} Read a.
  Proof.
    intros.
    step.
    exists (diskIs (mem_except d a)).
    eexists; intuition eauto.

    step.
    repeat match goal with
           | [ |- exists _, _ ] => eexists
           end; intuition eauto.

    step.
    apply diskIs_combine_same in H2.
    unfold diskIs in H2; auto.
    eexists.
    pred_apply; cancel.
  Qed.

  Definition StartRead_upd {Sigma} a : prog Sigma _ :=
    StartRead a;;
              Ret tt.

Theorem StartRead_upd_ok : forall Sigma (delta:Protocol Sigma) a,
    SPEC delta, tid |-
    {{ v0,
     | PRE d m s_i s: d a = Some (v0, None)
     | POST d' m' s_i' s' _: d' = upd d a (v0, Some tid) /\
                            s_i' = s_i /\
                            s' = s /\
                            m' = m
    }} StartRead_upd a.
Proof.
  intros.
  step.
  exists (diskIs (mem_except d a)).
  eexists; intuition eauto.

  step.
  eapply diskIs_combine_upd in H; unfold diskIs in H.
  auto.
Qed.

Definition FinishRead_upd {Sigma} a : prog Sigma _ :=
  v <- FinishRead a;
            Ret v.

Theorem FinishRead_upd_ok : forall Sigma (delta:Protocol Sigma) a,
    SPEC delta, tid |-
    {{ v,
     | PRE d m s_i s: d a = Some (v, Some tid)
     | POST d' m' s_i' s' r: d' = upd d a (v, None) /\
                            s_i' = s_i /\
                            s' = s /\
                            m' = m /\
                            r = v
    }} FinishRead_upd a.
Proof.
  intros.
  step.
  exists (diskIs (mem_except d a)).
  eexists; intuition eauto.

  step.
  eapply diskIs_combine_upd in H; unfold diskIs in H.
  eauto.
Qed.

Definition Write_upd {Sigma} a v : prog Sigma _ :=
  Write a v;;
        Ret tt.

Theorem Write_upd_ok : forall Sigma (delta: Protocol Sigma) a v,
    SPEC delta, tid |-
    {{ v0,
     | PRE d m s_i s: d a = Some (v0, None)
     | POST d' m' s_i' s' r: d' = upd d a (v, None) /\
                            s_i' = s_i /\
                            s' = s /\
                            m' = m
    }} Write_upd a v.
Proof.
  intros.
  step.
  exists (diskIs (mem_except d a)).
  eexists; intuition eauto.

  step.
  eapply diskIs_combine_upd in H; unfold diskIs in H.
  eauto.
Qed.

End ReadWriteTheorems.

Hint Extern 1 {{Read _; _}} => apply Read_ok : prog.
Hint Extern 1 {{StartRead_upd _; _}} => apply StartRead_upd_ok : prog.
Hint Extern 1 {{FinishRead_upd _; _}} => apply FinishRead_upd_ok : prog.
Hint Extern 1 {{Write_upd _ _; _}} => apply Write_upd_ok : prog.

Section WaitForCombinator.

CoFixpoint wait_for {Sigma}
           tv (v: var (mem_types Sigma) tv) {P} (test: forall val, {P val} + {~P val}) (wchan: addr)
  : prog Sigma _ :=
  val <- Get v;
  if (test val) then (
    Ret tt
  ) else (
    Yield wchan;;
    wait_for v test wchan
    ).

(* dummy function that will trigger computation of cofix *)
Definition prog_frob Sigma T (p: prog Sigma T) : prog Sigma T :=
  match p with
  | StartRead a => StartRead a
  | FinishRead a => FinishRead a
  | Write a v => Write a v
  | Sync a => Sync a
  | Get v => Get v
  | Assgn v val => Assgn v val
  | GetTID => GetTID
  | Yield wchan => Yield wchan
  | Wakeup wchan => Wakeup wchan
  | GhostUpdate update => GhostUpdate update
  | Ret v => Ret v
  | Bind p1 p2 => Bind p1 p2
  end.

Theorem prog_frob_eq : forall Sigma T (p: prog Sigma T),
    p = prog_frob p.
Proof.
  destruct p; reflexivity.
Qed.

Theorem wait_for_expand : forall Sigma tv (v: var (mem_types Sigma) tv)
                            P (test: forall val, {P val} + {~ P val})
                            wchan,
    wait_for v test wchan =
    val <- Get v;
    if (test val) then (
        Ret tt
    ) else (
        Yield wchan;;
        wait_for v test wchan
    ).
Proof.
  intros.
  match goal with
  | [ |- ?p1 = _ ] =>
    rewrite (prog_frob_eq p1) at 1
  end; cbn.
  auto.
Qed.

Ltac inv_st :=
  match goal with
  | [ H : @eq state _ _ |- _ ] =>
    inversion H
  end.

Ltac inv_tuple :=
  match goal with
  | [ H : (_, _, _, _) = (_, _, _, _) |- _ ] =>
    inversion H; subst
  end.

Ltac inv_prog :=
  match goal with
  | [ H: @eq (prog _ _) _ _ |- _ ] =>
    inversion H
  end.

Ltac inv_fail_step :=
  match goal with
  | [ H: context[fail_step] |- _ ] =>
    inversion H; subst;
    (* produce equalities from dependent equalities using proof
      irrelevance *)
    repeat sigT_eq;
    (* get rid of local definitions in context *)
    repeat match goal with
           | [ v := _ : _ |- _ ] => subst v
           end
  end.

Ltac ind_exec :=
  match goal with
  | [ H : exec _ _ _ ?p ?st _ |- _ ] =>
    remember st; remember p;
    induction H; subst;
    try (destruct st; inv_st);
    try inv_tuple;
    try inv_step;
    try inv_prog;
    intuition (subst; eauto)
  end.

Hint Constructors exec.

Lemma rely_stutter : forall Sigma (delta: Protocol Sigma) tid s,
    rely delta tid s s.
Proof.
  unfold rely; eauto.
Qed.

Lemma guar_stutter : forall Sigma (delta: Protocol Sigma),
    forall tid s, guar delta tid s s.
Proof.
  intros.
  destruct delta.
  apply guar_refl_trans; eauto.
Qed.

Hint Resolve rely_stutter.
Hint Resolve guar_stutter.

Transparent valid.

Lemma exec_get : forall Sigma delta T tid d m s_i s out tv v (rx: tv -> prog Sigma T),
    exec delta tid (x <- Get v; rx x) (d, m, s_i, s) out ->
    exec delta tid (rx (get v m)) (d, m, s_i, s) out.
Proof.
  intros; inv_exec.
  inv_exec' H5; eauto.
  inv_exec' H5; eauto.
Qed.

Lemma exec_yield : forall Sigma delta T tid d m s_i s out wchan (rx: prog Sigma T),
    exec delta tid (Yield wchan;; rx) (d, m, s_i, s) out ->
    invariant delta d m s ->
    guar delta tid s_i s ->
    exists d' m' s',
      invariant delta d' m' s' /\
      rely delta tid s s' /\
      exec delta tid rx (d', m', s', s') out.
Proof.
  intros.
  inv_exec.
  destruct st' as [ [ [? ?] ? ] ?].
  inv_exec' H7; inv_step.
  repeat eexists; eauto.

  inv_exec' H7; intuition.
Qed.

Theorem wait_for_ok : forall Sigma (delta: Protocol Sigma)
                        tv (v: var (mem_types Sigma) tv)
                        P (test: forall v, {P v} + {~ P v}) wchan,
  SPEC delta, tid |-
    {{ (_:unit),
     | PRE d m s_i s:
       invariant delta d m s /\
       guar delta tid s_i s
     | POST d' m' s_i' s' r:
       invariant delta d' m' s' /\
       (exists H, test (get v m') = left H) /\
       rely delta tid s s' /\
       guar delta tid s_i' s'
    }} wait_for v test wchan.
Proof.
  intros; cbn.
  apply valid_unfold; intros.
  rewrite wait_for_expand in H0.
  repeat deex; intuition.
  apply bind_assoc in H0.

  match goal with
  | [ H: exec _ _ ?p ?st _ |- _ ] =>
    remember p
  end.

  remember (d, m, s_i, s) as st.
  generalize dependent d.
  generalize dependent m.
  generalize dependent s_i.
  generalize dependent s.
  generalize dependent st.
  induction 1; intros; subst.

  - inversion Heqp.
  - inv_step.
  - inversion Heqp.
    subst tv.
    repeat sigT_eq.

    inv_exec' H0_.
    destruct (test (get v m)) eqn:Htest.
    (* easy case - exit loop *)
    + apply bind_left_id in H0_0.
      eapply H2; intuition eauto.
    + apply bind_assoc in H0_0.
      apply exec_yield in H0_0; eauto;
        repeat deex.
      (* need to apply inductive hypothesis, but need notion of
      two-step execution so hypothesis has an expanded wait_for
      equality we can actually prove *)
      admit.
  - inversion Heqp; subst;
      repeat sigT_eq.
    inv_exec' H0; inv_fail_step.
  - inv_fail_step.
Admitted.

End WaitForCombinator.

Hint Extern 1 {{ wait_for _ _ _; _ }} => apply wait_for_ok : prog.

Section GhostVarUpdate.

Definition var_update {Sigma}
  tv (v: var (abstraction_types Sigma) tv)
  (up: tv -> tv) : prog Sigma _ :=
  GhostUpdate (fun s =>
    set v (up (get v s)) s);;
    Ret tt.

Theorem var_update_ok : forall Sigma (delta: Protocol Sigma)
                        tv (v: var (abstraction_types Sigma) tv) up,
  SPEC delta, tid |-
  {{ (_:unit),
   | PRE d m s_i s: True
   | POST d' m' s_i' s' r:
     m' = m /\
     d' = d /\
     s_i' = s_i /\
     s' = set v (up (get v s)) s
  }} var_update v up.
Proof.
  hoare.
Qed.

End GhostVarUpdate.

Hint Extern 1 {{ var_update _ _; _ }} => apply var_update_ok : prog.

Lemma flag_not_open : forall flag, flag <> Open ->
                              flag = Locked.
Proof.
  intros; destruct flag; congruence.
Qed.

Definition is_unlocked (flag : BusyFlag) : {flag = Open} + {flag <> Open}.
Proof.
  destruct flag; eauto.
  right; intro H; inversion H.
Defined.

Definition AcquireLock {Sigma}
                       (l : var (mem_types Sigma) BusyFlag)
                       (lock_ghost : TID -> abstraction Sigma -> abstraction Sigma)
                       (wchan : addr) :=
  wait_for l is_unlocked wchan;;
  tid <- GetTID;
  GhostUpdate (lock_ghost tid);;
  Assgn l Locked;;
  Ret tt.

Theorem AcquireLock_ok : forall Sigma (delta: Protocol Sigma)
                        (R_trans : forall tid s1 s2, star (guar delta tid) s1 s2 -> guar delta tid s1 s2)
                        l up wchan,
    SPEC delta, tid |-
    {{ (_:unit),
     | PRE d m s_i s:
         invariant delta d m s /\
         guar delta tid s_i s
     | POST d' m'' s_i' s'' _:
         exists m' s',
           rely delta tid s s' /\
           invariant delta d' m' s' /\
           m'' = set l Locked m' /\
           s'' = up tid s' /\
           guar delta tid s_i' s' /\
           get l m'' = Locked
    }} AcquireLock l up wchan.
Proof.
  hoare.
  repeat eexists; eauto.
  simpl_get_set.
Qed.

Hint Extern 1 {{ AcquireLock _ _ _; _ }} => apply AcquireLock_ok : prog.