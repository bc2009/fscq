Require Import CCL.
Require Import FSLayout.

Require AsyncFS.
(* imports for DirTreeRep.rep *)
Import Log FSLayout Inode.INODE BFile.

(* various other imports *)
Export BFILE. (* importantly, exports memstate *)
Import SuperBlock.
Import GenSepN.
Import Pred.

Require Export HomeDirProtocol.
Require Export OptimisticTranslator.

Record FsParams :=
  { cache: ident; (* : Cache *)
    vdisk: ident; (* : Disk *)
    fsmem: ident; (* : memsstate *)
    fstree: ident; (* : dirtree *)
    fshomedirs: ident; (* thread_homes *)
    fsxp: fs_xparams;
  }.

Section FilesystemProtocol.

  Variable P:FsParams.

  Definition fs_rep vd hm mscs tree :=
    exists ds ilist frees,
      LOG.rep (FSLayout.FSXPLog (fsxp P)) (SB.rep (fsxp P))
              (LOG.NoTxn ds) (MSLL mscs) hm (add_buffers vd) /\
      (DirTreeRep.rep (fsxp P) Pred.emp tree ilist frees mscs)
        (list2nmem (ds!!)).

  Definition fs_invariant d hm tree (homedirs: thread_homes) : heappred :=
    (fstree P |-> abs tree *
     fshomedirs P |-> abs homedirs *
     exists c vd mscs,
       cache P |-> val c *
       vdisk P |-> absMem vd *
       [[ CacheRep d c vd ]] *
       fsmem P |-> val mscs *
       [[ fs_rep vd hm mscs tree ]])%pred.

  Theorem fs_invariant_unfold : forall d hm tree homedirs h,
      fs_invariant d hm tree homedirs h ->
      exists c vd mscs,
        (fstree P |-> abs tree * fshomedirs P |-> abs homedirs *
         cache P |-> val c *
         vdisk P |-> absMem vd *
         fsmem P |-> val mscs)%pred h /\
        CacheRep d c vd /\
        fs_rep vd hm mscs tree.
  Proof.
    unfold fs_invariant; intros.
    SepAuto.destruct_lifts.
    descend; intuition eauto.
  Qed.

  Theorem fs_invariant_refold : forall tree homedirs d c vd hm mscs h,
      (fstree P |-> abs tree * fshomedirs P |-> abs homedirs *
       cache P |-> val c *
       vdisk P |-> absMem vd *
       fsmem P |-> val mscs)%pred h ->
      CacheRep d c vd ->
      fs_rep vd hm mscs tree ->
      fs_invariant d hm tree homedirs h.
  Proof.
    unfold fs_invariant; intros.
    SepAuto.pred_apply; SepAuto.cancel.
  Qed.

  Definition fs_guarantee tid (sigma sigma':Sigma) :=
    exists tree tree' homedirs,
      fs_invariant (Sigma.disk sigma) (Sigma.hm sigma) tree homedirs (Sigma.mem sigma) /\
      fs_invariant (Sigma.disk sigma') (Sigma.hm sigma') tree' homedirs (Sigma.mem sigma') /\
      homedir_guarantee tid homedirs tree tree' /\
      Sigma.l sigma' = Sigma.l sigma.

  Theorem fs_rely_same_fstree : forall tid sigma sigma' tree homedirs,
      fs_invariant (Sigma.disk sigma) (Sigma.hm sigma) tree homedirs (Sigma.mem sigma) ->
      fs_invariant (Sigma.disk sigma') (Sigma.hm sigma') tree homedirs (Sigma.mem sigma') ->
      Sigma.l sigma' = Sigma.l sigma ->
      Rely fs_guarantee tid sigma sigma'.
  Proof.
    intros.
    constructor.
    exists (S tid); intuition.
    unfold fs_guarantee.
    descend; intuition eauto.
    reflexivity.
  Qed.

  Section InvariantUniqueness.

    Ltac mem_eq m a v :=
      match goal with
      | [ H: context[ptsto a v] |- _ ] =>
        let Hptsto := fresh in
        assert ((exists F, F * a |-> v)%pred m) as Hptsto by
              (SepAuto.pred_apply' H; SepAuto.cancel);
        unfold exis in Hptsto; destruct Hptsto;
        apply ptsto_valid' in Hptsto
      end.

    Lemma fs_invariant_tree_unique : forall d hm tree homedirs
                                       d' hm' tree' homedirs' m,
        fs_invariant d hm tree homedirs m ->
        fs_invariant d' hm' tree' homedirs' m ->
        tree = tree'.
    Proof.
      unfold fs_invariant; intros.
      mem_eq m (fstree P) (abs tree).
      mem_eq m (fstree P) (abs tree').
      rewrite H1 in H2; inversion H2; inj_pair2.
      auto.
    Qed.

    Lemma fs_invariant_homedirs_unique : forall d hm tree homedirs
                                       d' hm' tree' homedirs' m,
        fs_invariant d hm tree homedirs m ->
        fs_invariant d' hm' tree' homedirs' m ->
        homedirs = homedirs'.
    Proof.
      unfold fs_invariant; intros.
      mem_eq m (fshomedirs P) (abs homedirs).
      mem_eq m (fshomedirs P) (abs homedirs').
      rewrite H1 in H2; inversion H2; inj_pair2.
      auto.
    Qed.

  End InvariantUniqueness.

  Ltac invariant_unique :=
    repeat match goal with
           | [ H: fs_invariant _ _ ?tree _ ?m,
                  H': fs_invariant _ _ ?tree' _ ?m |- _ ] =>
             first [ constr_eq tree tree'; fail 1 |
                     assert (tree' = tree) by
                         apply (fs_invariant_tree_unique H' H); subst ]
           | [ H: fs_invariant _ _ _ ?homedirs ?m,
                  H': fs_invariant _ _ _ ?homedirs' ?m |- _ ] =>
             first [ constr_eq homedirs homedirs'; fail 1 |
                     assert (homedirs' = homedirs) by
                         apply (fs_invariant_homedirs_unique H' H); subst ]
           end.

  Theorem fs_rely_invariant : forall tid sigma sigma' tree homedirs,
      fs_invariant (Sigma.disk sigma) (Sigma.hm sigma) tree homedirs (Sigma.mem sigma) ->
      Rely fs_guarantee tid sigma sigma' ->
      exists tree', fs_invariant (Sigma.disk sigma') (Sigma.hm sigma') tree' homedirs (Sigma.mem sigma').
  Proof.
    unfold fs_guarantee; intros.
    generalize dependent tree.
    induction H0; intros; repeat deex; eauto.
    invariant_unique.
    eauto.
    edestruct IHclos_refl_trans1; eauto.
  Qed.

  Lemma fs_rely_invariant' : forall tid sigma sigma',
      Rely fs_guarantee tid sigma sigma' ->
      forall tree homedirs,
        fs_invariant (Sigma.disk sigma) (Sigma.hm sigma) tree homedirs (Sigma.mem sigma) ->
        exists tree',
          fs_invariant (Sigma.disk sigma') (Sigma.hm sigma') tree' homedirs (Sigma.mem sigma').
  Proof.
    intros.
    eapply fs_rely_invariant; eauto.
  Qed.

  Theorem fs_homedir_rely : forall tid sigma sigma' tree homedirs tree',
      fs_invariant (Sigma.disk sigma) (Sigma.hm sigma) tree homedirs (Sigma.mem sigma) ->
      Rely fs_guarantee tid sigma sigma' ->
      fs_invariant (Sigma.disk sigma') (Sigma.hm sigma') tree' homedirs (Sigma.mem sigma') ->
      homedir_rely tid homedirs tree tree'.
  Proof.
    unfold fs_guarantee; intros.
    generalize dependent tree'.
    generalize dependent tree.
    apply Operators_Properties.clos_rt_rt1n in H0.
    induction H0; intros; repeat deex; invariant_unique.
    - reflexivity.
    - match goal with
      | [ H: homedir_guarantee _ _ _ _ |- _ ] =>
        specialize (H _ ltac:(eauto))
      end.
      specialize (IHclos_refl_trans_1n _ ltac:(eauto) _ ltac:(eauto)).
      unfold homedir_rely in *; congruence.
  Qed.

  Theorem fs_lock_rely : forall tid sigma sigma',
      Rely fs_guarantee tid sigma sigma' ->
      Sigma.l sigma' = Sigma.l sigma.
  Proof.
    unfold fs_guarantee; intros.
    apply Operators_Properties.clos_rt_rt1n in H.
    induction H; intros; repeat deex; congruence.
  Qed.

  Lemma fs_rely_preserves_subtree : forall tid sigma sigma' tree homedirs tree' path f,
      find_subtree (homedirs tid ++ path) tree = Some f ->
      fs_invariant (Sigma.disk sigma) (Sigma.hm sigma) tree homedirs (Sigma.mem sigma) ->
      Rely fs_guarantee tid sigma sigma' ->
      fs_invariant (Sigma.disk sigma') (Sigma.hm sigma') tree' homedirs (Sigma.mem sigma') ->
      find_subtree (homedirs tid ++ path) tree' = Some f.
  Proof.
    intros.
    eapply fs_homedir_rely in H1; eauto.
    unfold homedir_rely in H1.
    eapply find_subtree_app' in H; repeat deex.
    erewrite find_subtree_app; eauto.
    congruence.
  Qed.

  Theorem fs_guarantee_refl : forall tid sigma homedirs,
      (exists tree, fs_invariant (Sigma.disk sigma) (Sigma.hm sigma) tree homedirs (Sigma.mem sigma)) ->
      fs_guarantee tid sigma sigma.
  Proof.
    intros; deex.
    unfold fs_guarantee; descend; intuition eauto.
    reflexivity.
  Qed.

  Theorem fs_guarantee_trans : forall tid sigma sigma' sigma'',
      fs_guarantee tid sigma sigma' ->
      fs_guarantee tid sigma' sigma'' ->
      fs_guarantee tid sigma sigma''.
  Proof.
    unfold fs_guarantee; intuition.
    repeat deex; invariant_unique.

    descend; intuition eauto.
    etransitivity; eauto.
    congruence.
  Qed.

End FilesystemProtocol.