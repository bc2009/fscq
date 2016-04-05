Require Import Arith.
Require Import Bool.
Require Import List.
Require Import Classes.SetoidTactics.
Require Import Pred PredCrash.
Require Import Prog.
Require Import Hoare.
Require Import BasicProg.
Require Import FunctionalExtensionality.
Require Import Omega.
Require Import Word.
Require Import Rec.
Require Import Array.
Require Import Eqdep_dec.
Require Import WordAuto.
Require Import Cache.
Require Import Idempotent.
Require Import ListUtils.
Require Import FSLayout.
Require Import DiskLog.
Require Import AsyncDisk.
Require Import SepAuto.
Require Import GenSepN.
Require Import MapUtils.
Require Import FMapFacts.
Require Import Lock.
Require Import LogReplay.

Import ListNotations.

Set Implicit Arguments.


Module MLog.

  Import AddrMap LogReplay.

  Record memstate := mk_memstate {
    MSInLog : valumap;      (* memory state for committed (but unapplied) txns *)
    MSCache : cachestate    (* cache state *)
  }.

  Inductive logstate :=
  | Synced  (na : nat) (d : diskstate)
  (* Synced state: both log and disk content are synced *)

  | Flushing (d : diskstate) (ents : DLog.contents)
  (* A transaction is being flushed to the log, but not sync'ed yet
   * e.g. DiskLog.ExtendedUnsync or DiskLog.Extended *)

  | Applying (d : diskstate)
  (* In the process of applying the log to real disk locations.
     Block content might or might not be synced.
     Log might be truncated but not yet synced.
     e.g. DiskLog.Synced or DiskLog.Truncated
   *)
  .

  Definition equal_unless_in (keys: list addr) (l1 l2: list valuset) :=
    length l1 = length l2 /\
    forall a,  ~ In a keys -> selN l1 a ($0, nil) = selN l2 a ($0, nil).

  Definition synced_rep xp (d : diskstate) : rawpred :=
    arrayN (DataStart xp) d.

  Definition unsync_rep xp (ms : valumap) (old : diskstate) : rawpred :=
    (exists vs, [[ equal_unless_in (map_keys ms) old vs ]] *
     arrayN (DataStart xp) vs
    )%pred.

  Definition rep_inner xp st ms :=
    ( exists log d0,
      [[ Map.Equal ms (replay_mem log vmap0) ]] *
      [[ goodSize addrlen (length d0) /\ map_valid ms d0 ]] *
    match st with
    | Synced na d =>
        [[ map_replay ms d0 d ]] *
        synced_rep xp d0 *
        DLog.rep xp (DLog.Synced na log)
    | Flushing d ents =>
        [[ log_valid ents d /\ map_replay ms d0 d ]] *
        synced_rep xp d0 *
        (DLog.rep xp (DLog.ExtendedUnsync log)
      \/ DLog.rep xp (DLog.Extended log ents))
    | Applying d => exists na,
        [[ map_replay ms d0 d ]] *
        (((DLog.rep xp (DLog.Synced na log)) *
          (unsync_rep xp ms d0))
      \/ ((DLog.rep xp (DLog.Truncated log)) *
          (synced_rep xp d)))
    end)%pred.


  Definition rep xp F st ms := 
    ( exists d, BUFCACHE.rep (MSCache ms) d *
      [[ (F * rep_inner xp st (MSInLog ms))%pred d ]])%pred.


  (* some handy state wrappers used in crash conditons *)

  Definition would_recover_before xp F d :=
    (exists ms', rep xp F (Applying d) ms' \/
     exists na', rep xp F (Synced na' d) ms')%pred.

  Definition would_recover_either xp F d ents :=
     (exists ms',
      (exists na', rep xp F (Synced na' d) ms') \/
      (exists na', rep xp F (Synced na' (replay_disk ents d)) ms') \/
      rep xp F (Flushing d ents) ms' \/
      rep xp F (Applying d) ms')%pred.


  (******************  Program *)

  Definition read T xp a ms rx : prog T :=
    let '(oms, cs) := (MSInLog ms, MSCache ms) in
    match Map.find a oms with
    | Some v => rx ^(ms, v)
    | None =>
        let^ (cs, v) <- BUFCACHE.read_array (DataStart xp) a cs;
        rx ^(mk_memstate oms cs, v)
    end.

  Definition flush_noapply T xp ents ms rx : prog T :=  
    let '(oms, cs) := (MSInLog ms, MSCache ms) in
    let^ (cs, ok) <- DLog.extend xp ents cs;
    If (bool_dec ok true) {
      rx ^(mk_memstate (replay_mem ents oms) cs, true)
    } else {
      rx ^(mk_memstate oms cs, false)
    }.

  Definition apply T xp ms rx : prog T :=
    let '(oms, cs) := (MSInLog ms, MSCache ms) in
    cs <- BUFCACHE.write_vecs (DataStart xp) (Map.elements oms) cs;
    cs <- BUFCACHE.sync_vecs (DataStart xp) (map_keys oms) cs;
    cs <- DLog.trunc xp cs;
    rx (mk_memstate vmap0 cs).

  Definition flush T xp ents ms rx : prog T :=
    let '(oms, cs) := (MSInLog ms, MSCache ms) in
    let^ (cs, na) <- DLog.avail xp cs;
    let ms := (mk_memstate oms cs) in
    ms' <- IfRx irx (lt_dec na (length ents)) {
      ms <- apply xp ms;
      irx ms
    } else {
      irx ms
    };
    r <- flush_noapply xp ents ms';
    rx r.


  Definition dwrite T xp a v ms rx : prog T :=
    let '(oms, cs) := (MSInLog ms, MSCache ms) in
    ms' <- IfRx irx (MapFacts.In_dec oms a) {
      ms <- apply xp ms;
      irx ms
    } else {
      irx ms
    };
    cs' <- BUFCACHE.write_array (DataStart xp) a v (MSCache ms');
    rx (mk_memstate (MSInLog ms') cs').


  Definition dsync T xp a ms rx : prog T :=
    let '(oms, cs) := (MSInLog ms, MSCache ms) in
    cs' <- BUFCACHE.sync_array (DataStart xp) a cs;
    rx (mk_memstate oms cs').


  Arguments DLog.rep: simpl never.
  Hint Extern 0 (okToUnify (DLog.rep _ _) (DLog.rep _ _)) => constructor : okToUnify.




  (****** auxiliary lemmas *)

  Lemma equal_unless_in_length_eq : forall a b l,
    equal_unless_in l a b -> length b = length a.
  Proof.
    unfold equal_unless_in; firstorder.
  Qed.

  Lemma apply_synced_data_ok' : forall l d,
    NoDup (map fst l) ->
    vssync_vecs (vsupd_vecs d l) (map fst l) = replay_disk l d.
  Proof.
    induction l; intros; simpl; auto.
    destruct a; simpl.
    inversion H; subst.
    rewrite <- IHl by auto.

    rewrite vsupd_vecs_vsupd_notin by auto.
    rewrite vssync_vsupd_eq.
    rewrite updN_vsupd_vecs_notin; auto.
  Qed.

  Lemma apply_synced_data_ok : forall xp m d,
    arrayN (DataStart xp) (vssync_vecs (vsupd_vecs d (Map.elements m)) (map_keys m))
    =p=> synced_rep xp (replay_disk (Map.elements m) d).
  Proof.
    unfold synced_rep; intros.
    apply arrayN_unify.
    apply apply_synced_data_ok'.
    apply KNoDup_NoDup; auto.
  Qed.


  Lemma apply_unsync_applying_ok' : forall l d n,
    NoDup (map fst l) ->
    equal_unless_in (map fst l) d (vsupd_vecs d (firstn n l)).
  Proof.
    unfold equal_unless_in; induction l; intros; simpl.
    rewrite firstn_nil; simpl; intuition.
    split; intuition;
    destruct n; simpl; auto;
    destruct a; inversion H; simpl in *; intuition; subst.

    rewrite vsupd_vecs_vsupd_notin.
    rewrite vsupd_length, vsupd_vecs_length; auto.
    rewrite <- firstn_map_comm.
    contradict H2.
    eapply in_firstn_in; eauto.

    pose proof (IHl d n H5) as [Hx Hy].
    rewrite Hy by auto.
    rewrite vsupd_vecs_vsupd_notin.
    unfold vsupd; rewrite selN_updN_ne; auto.
    rewrite <- firstn_map_comm.
    contradict H4.
    eapply in_firstn_in; eauto.
  Qed.


  Lemma apply_unsync_applying_ok : forall xp m d n,
    arrayN (DataStart xp) (vsupd_vecs d (firstn n (Map.elements m)))
       =p=> unsync_rep xp m d.
  Proof.
    unfold unsync_rep, map_replay; cancel.
    apply apply_unsync_applying_ok'.
    apply KNoDup_NoDup; auto.
  Qed.

  Lemma apply_unsync_syncing_ok' : forall l a d n,
    NoDup (map fst l) ->
    ~ In a (map fst l) ->
    selN d a ($0, nil) = selN (vssync_vecs (vsupd_vecs d l) (firstn n (map fst l))) a ($0, nil).
  Proof.
    induction l; intros; simpl.
    rewrite firstn_nil; simpl; auto.

    destruct a; inversion H; simpl in *; subst; intuition.
    destruct n; simpl; auto.
    rewrite vsupd_vecs_vsupd_notin by auto.
    unfold vsupd.
    rewrite selN_updN_ne by auto.
    rewrite vsupd_selN_not_in; auto.

    unfold vssync.
    rewrite -> updN_vsupd_vecs_notin by auto.
    rewrite <- IHl; auto.
    rewrite selN_updN_ne by auto.
    unfold vsupd.
    rewrite selN_updN_ne; auto.
  Qed.

  Lemma apply_unsync_syncing_ok : forall xp m d n,
    arrayN (DataStart xp) (vssync_vecs (vsupd_vecs d (Map.elements m)) (firstn n (map_keys m)))
       =p=> unsync_rep xp m d.
  Proof.
    unfold unsync_rep, equal_unless_in; cancel.
    rewrite vssync_vecs_length, vsupd_vecs_length; auto.
    apply apply_unsync_syncing_ok'.
    apply KNoDup_NoDup; auto.
    eauto.
  Qed.



  Theorem recover_before_either : forall xp F d ents,
    would_recover_before xp F d =p=>
    would_recover_either xp F d ents.
  Proof.
    unfold would_recover_before, would_recover_either; cancel.
  Qed.

  Theorem synced_recover_before : forall xp F na d ms,
    rep xp F (Synced na d) ms =p=>
    would_recover_before xp F d.
  Proof.
    unfold would_recover_before; cancel.
  Qed.

  Theorem synced_recover_either : forall xp F na d ms ents,
    rep xp F (Synced na d) ms =p=>
    would_recover_either xp F d ents.
  Proof.
    unfold would_recover_either; cancel.
  Qed.

  Theorem applying_recover_before : forall xp F d ms,
    rep xp F (Applying d) ms =p=>
    would_recover_before xp F d.
  Proof.
    unfold would_recover_before; cancel.
  Qed.

  Theorem synced_recover_after : forall xp F na d ms ents,
    rep xp F (Synced na (replay_disk ents d)) ms =p=>
    would_recover_either xp F d ents.
  Proof.
    unfold would_recover_either; intros.
    (** FIXME:
     * `cancel` works slowly when there are existentials.
     *  (when calling `apply finish_frame`)
     *)
    norm; unfold stars; simpl; auto.
    or_r; or_l; cancel.
  Qed.

  Theorem applying_recover_after : forall xp F d ms ents,
    rep xp F (Applying d) ms =p=>
    would_recover_either xp F d ents.
  Proof.
    unfold would_recover_either; cancel.
  Qed.

  Theorem flushing_recover_after : forall xp F d ms ents,
    rep xp F (Flushing d ents) ms =p=>
    would_recover_either xp F d ents.
  Proof.
    unfold would_recover_either; intros.
    norm; unfold stars; simpl; auto.
    or_r; or_r; cancel.
  Qed.



  (* destruct memstate *)
  Ltac dems := eauto; try match goal with
  | [ H : @eq memstate ?ms (mk_memstate _ _ _) |- _ ] =>
     destruct ms; inversion H; subst
  end; eauto.



  (** specs *)

  Hint Extern 0 (okToUnify (synced_rep ?a _) (synced_rep ?a _)) => constructor : okToUnify.

  Section UnfoldProof1.
  Local Hint Unfold rep map_replay rep_inner: hoare_unfold.

  Theorem read_ok: forall xp ms a,
    {< F d na vs,
    PRE
      rep xp F (Synced na d) ms *
      [[[ d ::: exists F', (F' * a |-> vs) ]]]
    POST RET:^(ms', r)
      rep xp F (Synced na d) ms' * [[ r = fst vs ]]
    CRASH
      exists ms', rep xp F (Synced na d) ms'
    >} read xp a ms.
  Proof.
    unfold read.
    prestep.

    cancel.
    step.
    subst.
    eapply replay_disk_eq; eauto.
    eassign dummy1; pred_apply; cancel.
    pimpl_crash; cancel; auto. cancel.

    unfold synced_rep; cancel.
    subst; eapply synced_data_replay_inb; eauto.
    eassign ((Map.elements (MSInLog ms))); pred_apply; cancel.

    prestep.
    cancel; subst; auto.
    unfold pred_apply in *.
    assert (selN dummy1 a ($0, nil) = (vs_cur, vs_old)) as Hx.
    eapply replay_disk_none_selN; eauto.
    pred_apply; cancel.
    destruct (selN _ a _); inversion Hx; auto.

    pimpl_crash.
    norm.
    cancel.
    eassign (mk_memstate (MSInLog ms) cs').
    cancel.
    intuition; subst; simpl; eauto.
    pred_apply; cancel.
  Qed.

  End UnfoldProof1.



  Local Hint Resolve log_valid_nodup.


  Section UnfoldProof2.
  Local Hint Unfold rep map_replay rep_inner synced_rep: hoare_unfold.

  Theorem flush_noapply_ok: forall xp ents ms,
    {< F d na,
     PRE  rep xp F (Synced na d) ms *
          [[ log_valid ents d ]]
     POST RET:^(ms',r)
          ([[ r = true ]]  * exists na',
            rep xp F (Synced na' (replay_disk ents d)) ms') \/
          ([[ r = false /\ length ents > na ]] *
            rep xp F (Synced na d) ms')
     CRASH  exists ms' na',
            rep xp F (Synced na' d) ms' \/
            rep xp F (Synced na' (replay_disk ents d)) ms' \/
            rep xp F (Flushing d ents) ms'
    >} flush_noapply xp ents ms.
  Proof.
    unfold flush_noapply.
    step using dems.
    eapply log_valid_entries_valid; eauto.
    hoare using dems.

    or_l.
    cancel; unfold map_merge.
    rewrite replay_mem_app; eauto.
    apply MapFacts.Equal_refl.
    apply map_valid_replay_mem'; auto.
    eapply log_valid_replay; eauto.
    apply replay_disk_replay_mem; auto.

    (* crashes *)
    or_l; norm.
    eassign (mk_memstate (MSInLog ms) cs').
    cancel. intuition; simpl; eauto.
    pred_apply; cancel.

    or_r; or_r.
    norm. cancel.
    eassign (mk_memstate (MSInLog ms) cs').
    cancel. intuition; simpl; eauto.
    pred_apply; cancel; eauto.
    or_l; auto.

    or_r; or_r.
    norm. cancel.
    eassign (mk_memstate (MSInLog ms) cs').
    cancel. intuition; simpl; eauto.
    pred_apply; cancel; eauto.
    or_r; auto.

    or_r; or_l; norm.
    eassign (mk_memstate (replay_mem ents (MSInLog ms)) cs').
    cancel. simpl; intuition; eauto.
    pred_apply; cancel.
    rewrite replay_mem_app; eauto.
    apply MapFacts.Equal_refl.
    apply map_valid_replay_mem'.
    eapply log_valid_replay; eauto. auto.
    apply replay_disk_replay_mem; auto.
    Unshelve. all: eauto.
  Qed.

  End UnfoldProof2.



  Section UnfoldProof3.
  Local Hint Unfold rep map_replay rep_inner would_recover_before: hoare_unfold.
  Hint Extern 0 (okToUnify (synced_rep ?a _) (synced_rep ?a _)) => constructor : okToUnify.

  Theorem apply_ok: forall xp ms,
    {< F d na,
    PRE
      rep xp F (Synced na d) ms
    POST RET:ms'
      rep xp F (Synced (LogLen xp) d) ms' *
      [[ Map.Empty (MSInLog ms') ]]
    CRASH would_recover_before xp F d
    >} apply xp ms.
  Proof.
    unfold apply; intros.
    step.
    unfold synced_rep; cancel.
    step.
    rewrite vsupd_vecs_length.
    apply map_valid_Forall_synced_map_fst; auto.
    step.
    step.

    rewrite vssync_vecs_length, vsupd_vecs_length; auto.
    apply map_valid_map0.
    rewrite apply_synced_data_ok'; auto.
    apply KNoDup_NoDup; auto.

    (* crash conditions *)
    or_r. norm.
    eassign (mk_memstate (MSInLog ms) cs).
    cancel.
    intuition; simpl; eauto.
    pred_apply; norm.
    eassign (replay_disk (Map.elements (MSInLog ms)) dummy0).
    cancel.

    rewrite apply_synced_data_ok; cancel.
    intuition.
    rewrite replay_disk_length; auto.
    apply map_valid_replay; auto.

    rewrite replay_disk_merge.
    setoid_rewrite mapeq_elements at 2; eauto.
    apply map_merge_id.

    (* truncated *)
    or_l. norm.
    eassign (mk_memstate (MSInLog ms) cs).
    cancel.
    intuition; simpl; eauto.
    pred_apply; cancel; eauto.
    or_r; cancel.
    rewrite apply_synced_data_ok; cancel.

    (* synced nil *)
    or_r. norm.
    eassign (mk_memstate vmap0 cs).
    cancel. intuition.
    pred_apply; norm.
    instantiate (1 := nil).
    eassign (replay_disk (Map.elements (MSInLog ms)) dummy0).
    cancel.
    rewrite apply_synced_data_ok; cancel.
    intuition.
    apply MapFacts.Equal_refl.
    rewrite replay_disk_length; eauto.
    apply map_valid_map0.

    (* unsync_syncing *)
    or_l. norm.
    eassign (mk_memstate (MSInLog ms) cs').
    cancel.
    intuition; simpl; eauto.
    pred_apply; cancel; eauto.
    or_l; cancel.
    apply apply_unsync_syncing_ok.

    (* unsync_applying *)
    or_l. norm.
    eassign (mk_memstate (MSInLog ms) cs').
    cancel.
    intuition; simpl; eauto.
    pred_apply; cancel; eauto.
    or_l; cancel.
    apply apply_unsync_applying_ok.
    Unshelve. eauto.
  Qed.

  End UnfoldProof3.


  Local Hint Unfold map_replay : hoare_unfold.
  Hint Extern 1 ({{_}} progseq (apply _ _) _) => apply apply_ok : prog.
  Hint Extern 1 ({{_}} progseq (flush_noapply _ _ _) _) => apply flush_noapply_ok : prog.
  Hint Extern 0 (okToUnify (synced_rep ?a _) (synced_rep ?a _)) => constructor : okToUnify.

  Theorem flush_ok: forall xp ents ms,
    {< F d na,
     PRE  rep xp F (Synced na d) ms *
          [[ log_valid ents d ]]
     POST RET:^(ms',r) exists na',
          ([[ r = true ]] *
            rep xp F (Synced na' (replay_disk ents d)) ms')
          \/
          ([[ r = false /\ length ents > (LogLen xp) ]] *
            rep xp F (Synced na' d) ms')
     CRASH  would_recover_either xp F d ents
    >} flush xp ents ms.
  Proof.
    unfold flush; intros.

    (* Be careful: only unfold rep in the preconditon,
       otherwise the goal will get messy as there are too many
       disjuctions in post/crash conditons *)
    prestep.
    unfold rep at 1, rep_inner at 1.
    cancel.
    step.

    (* case 1: apply happens *)
    prestep.
    unfold rep at 1, rep_inner at 1.
    cancel; auto.
    step.
    step.

    (* crashes *)
    rewrite synced_recover_either; cancel.
    rewrite synced_recover_after; cancel.
    rewrite flushing_recover_after; cancel.
    subst; pimpl_crash; rewrite recover_before_either; cancel.

    (* case 2: no apply *)
    prestep.
    unfold rep at 1, rep_inner at 1.
    cancel; auto.
    step.

    (* crashes *)
    cancel.
    apply synced_recover_either.
    apply synced_recover_after.
    apply flushing_recover_after.

    pimpl_crash; unfold would_recover_either; cancel.
    or_l; eassign (mk_memstate (MSInLog ms) cs').
    unfold rep, rep_inner; cancel; auto.
  Qed.



  Hint Extern 0 (okToUnify (rep _ _ _ _) (rep _ _ _ _)) => constructor : okToUnify.

  Theorem dwrite_ok: forall xp a v ms,
    {< F Fd d na vs,
    PRE
      rep xp F (Synced na d) ms *
      [[[ d ::: (Fd * a |-> vs) ]]]
    POST RET:ms' exists d' na',
      rep xp F (Synced na' d') ms' *
      [[ d' = updN d a (v, vsmerge vs) ]] *
      [[[ d' ::: (Fd * a |-> (v, vsmerge(vs))) ]]]
    CRASH
      would_recover_before xp F d \/
      exists ms' na' d',
      rep xp F (Synced na' d')  ms' *
      [[[ d' ::: (Fd * a |-> (v, vsmerge(vs))) ]]] *
      [[ d' = updN d a (v, vsmerge vs) ]]
    >} dwrite xp a v ms.
  Proof.
    unfold dwrite, would_recover_before.
    step.

    (* case 1: apply happens *)
    step.
    prestep.
    unfold rep at 1, rep_inner at 1; unfold synced_rep, map_replay in *.
    cancel; auto.
    replace (length _) with (length d).
    eapply list2nmem_inbound; eauto.
    subst; erewrite replay_disk_length; eauto.

    step.
    unfold rep, rep_inner, synced_rep, map_replay; cancel.
    unfold vsupd; autorewrite with lists; auto.
    apply map_valid_updN; auto.
    eapply replay_disk_updN_eq_empty; eauto.
    eapply list2nmem_updN; eauto.

    (* crashes for case 1 *)
    cancel.
    or_l; cancel; or_r.
    unfold rep, rep_inner, synced_rep, map_replay; cancel; eauto.
    eassign (mk_memstate  (MSInLog r_) cs'); cancel.
    pred_apply; cancel.

    or_r.
    unfold rep, rep_inner, synced_rep, map_replay; cancel; eauto.
    eassign (mk_memstate  (MSInLog r_) cs'); cancel.
    pred_apply; cancel.
    unfold vsupd; autorewrite with lists; auto.
    apply map_valid_updN; auto.
    eapply replay_disk_updN_eq_empty; eauto.
    eapply list2nmem_updN; eauto.

    or_l; unfold would_recover_before; cancel.

    (* case 2: no apply *)
    prestep.
    unfold rep, rep_inner, synced_rep, map_replay; cancel; eauto.
    replace (length _) with (length d).
    eapply list2nmem_inbound; eauto.
    subst; erewrite replay_disk_length; eauto.

    step.
    unfold rep, rep_inner, synced_rep, map_replay; cancel.
    unfold vsupd; autorewrite with lists; auto.
    apply map_valid_updN; auto.
    unfold eqlen, vsupd; autorewrite with lists; auto.
    eapply replay_disk_updN_eq_not_in; eauto.
    eapply list2nmem_updN; eauto.

    (* crashes for case 2 *)
    cancel.
    or_l; cancel; or_r.
    unfold rep, rep_inner, synced_rep, map_replay; cancel; eauto.
    eassign (mk_memstate (MSInLog ms) cs'); cancel.
    pred_apply; cancel.

    or_r.
    unfold rep, rep_inner, synced_rep, map_replay; cancel; eauto.
    eassign (mk_memstate  (MSInLog ms) cs'); cancel.
    pred_apply; cancel.
    unfold vsupd; autorewrite with lists; auto.
    apply map_valid_updN; auto.
    eapply replay_disk_updN_eq_not_in; eauto.
    eapply list2nmem_updN; eauto.
  Qed.



  Section UnfoldProof4.
  Local Hint Unfold rep map_replay rep_inner synced_rep: hoare_unfold.

  Theorem dsync_ok: forall xp a ms,
    {< F Fd d na vs,
    PRE
      rep xp F (Synced na d) ms *
      [[[ d ::: (Fd * a |-> vs) ]]]
    POST RET:ms' exists d' na',
      rep xp F (Synced na' d') ms' *
      [[[ d' ::: (Fd * a |-> (fst vs, nil)) ]]] *
      [[  d' = vssync d a ]]
    CRASH
      exists ms' na',
      rep xp F (Synced na' d)   ms' \/
      exists d',
      rep xp F (Synced na' d')  ms' *
      [[[ d' ::: (Fd * a |-> (fst vs, nil)) ]]] *
      [[ d' = vssync d a ]]
    >} dsync xp a ms.
  Proof.
    unfold dsync.
    step.
    subst; erewrite <- replay_disk_length.
    eapply list2nmem_inbound; eauto.

    step.
    unfold vssync; autorewrite with lists; auto.
    apply map_valid_updN; auto.
    apply replay_disk_vssync_comm.
    unfold vssync; erewrite <- list2nmem_sel; eauto; simpl.
    eapply list2nmem_updN; eauto.

    (* crashes *)
    eassign ( mk_memstate (MSInLog ms) cs').
    or_l; cancel.
    eassign (mk_memstate (MSInLog ms) cs').
    or_r; cancel.
    unfold vssync; autorewrite with lists; auto.
    apply map_valid_updN; auto.
    apply replay_disk_vssync_comm.
    unfold vssync; erewrite <- list2nmem_sel; eauto; simpl.
    eapply list2nmem_updN; eauto.
  Qed.

  End UnfoldProof4.




  (********* dwrite/dsync for a list of address/value pairs *)

  Fixpoint overlap V (l : list addr) (m : Map.t V) : bool :=
  match l with
  | nil => false
  | a :: rest => if (Map.mem a m) then true else overlap rest m
  end.


  Definition dwrite_vecs T xp avl ms rx : prog T :=
    let '(oms, cs) := (MSInLog ms, MSCache ms) in
    ms' <- IfRx irx (bool_dec (overlap (map fst avl) oms) true) {
      ms <- apply xp ms;
      irx ms
    } else {
      irx ms
    };
    cs' <- BUFCACHE.write_vecs (DataStart xp) avl (MSCache ms');
    rx (mk_memstate (MSInLog ms') cs').


  Definition dsync_vecs T xp al ms rx : prog T :=
    let '(oms, cs) := (MSInLog ms, MSCache ms) in
    cs' <- BUFCACHE.sync_vecs (DataStart xp) al cs;
    rx (mk_memstate oms cs').



  Lemma overlap_firstn_overlap : forall V n l (m : Map.t V),
    overlap (firstn n l) m = true ->
    overlap l m = true.
  Proof.
    induction n; destruct l; simpl; firstorder.
    destruct (MapFacts.In_dec m n0); auto.
    rewrite Map.mem_1; auto.
    apply MapFacts.not_mem_in_iff in n1; rewrite n1 in *; auto.
  Qed.

  Lemma In_MapIn_overlap : forall V l a (ms : Map.t V),
    In a l ->
    Map.In a ms ->
    overlap l ms = true.
  Proof.
    induction l; intros; simpl.
    inversion H.
    destruct (MapFacts.In_dec ms a); auto.
    rewrite Map.mem_1; auto.
    apply MapFacts.not_mem_in_iff in n as Hx; rewrite Hx in *; auto.
    inversion H; destruct (addr_eq_dec a a0); subst; firstorder.
  Qed.

  Lemma replay_disk_vsupd_vecs_nonoverlap : forall l m d,
    overlap (map fst l) m = false ->
    vsupd_vecs (replay_disk (Map.elements m) d) l =
    replay_disk (Map.elements m) (vsupd_vecs d l).
  Proof.
    induction l; simpl; intros; auto.
    destruct (MapFacts.In_dec m (fst a)); simpl in *.
    rewrite Map.mem_1 in H; congruence.
    apply MapFacts.not_mem_in_iff in n as Hx; rewrite Hx in *; auto.
    rewrite <- IHl by auto.
    unfold vsupd, vsmerge.
    rewrite replay_disk_updN_comm.
    erewrite replay_disk_selN_not_In; eauto.
    contradict n.
    apply In_map_fst_MapIn; eauto.
  Qed.


  Theorem dwrite_vecs_ok : forall xp avl ms,
    {< F d na,
    PRE
      rep xp F (Synced na d) ms *
      [[ Forall (fun e => fst e < length d) avl ]]
    POST RET:ms' exists na',
      rep xp F (Synced na' (vsupd_vecs d avl)) ms'
    CRASH
      would_recover_before xp F d \/
      exists ms' na' n,
      rep xp F (Synced na' (vsupd_vecs d (firstn n avl)))  ms'
    >} dwrite_vecs xp avl ms.
  Proof.
    unfold dwrite_vecs, would_recover_before.
    step.

    (* case 1: apply happens *)
    step.
    prestep.
    unfold rep at 1, rep_inner at 1.
    unfold synced_rep, map_replay in *.
    cancel; auto.
    erewrite <- replay_disk_length.
    denote replay_disk as Hx; rewrite <- Hx; auto.

    step.
    unfold rep, rep_inner, synced_rep, map_replay; cancel.
    rewrite vsupd_vecs_length; auto.
    apply map_valid_vsupd_vecs; auto.
    repeat rewrite replay_disk_empty; auto.

    (* crashes for case 1 *)
    cancel.
    or_r.
    unfold rep, rep_inner, synced_rep, map_replay; cancel; eauto.
    eassign (mk_memstate  (MSInLog r_) cs'); cancel.
    pred_apply; cancel.
    rewrite vsupd_vecs_length; auto.
    apply map_valid_vsupd_vecs; auto.
    repeat rewrite replay_disk_empty; auto.

    unfold would_recover_before; cancel.

    (* case 2: no apply *)
    prestep.
    unfold rep, rep_inner, synced_rep, map_replay; cancel; eauto.
    erewrite <- replay_disk_length.
    denote replay_disk as Hx; rewrite <- Hx; auto.

    step.
    unfold rep, rep_inner, synced_rep, map_replay; cancel.
    rewrite vsupd_vecs_length; auto.
    apply map_valid_vsupd_vecs; auto.
    apply replay_disk_vsupd_vecs_nonoverlap; auto.
    apply not_true_is_false; auto.

    (* crashes for case 2 *)
    cancel.
    or_r.
    unfold rep, rep_inner, synced_rep, map_replay; cancel; eauto.
    eassign (mk_memstate (MSInLog ms) cs'); cancel.
    pred_apply; cancel.
    rewrite vsupd_vecs_length; auto.
    apply map_valid_vsupd_vecs; auto.
    apply replay_disk_vsupd_vecs_nonoverlap.
    rewrite <- firstn_map_comm.
    apply not_true_is_false; auto.
    denote overlap as Hx; contradict Hx.
    eapply overlap_firstn_overlap; eauto.
  Qed.


  Theorem dsync_vecs_ok_strict: forall xp al ms,
    {< F d na,
    PRE
      rep xp F (Synced na d) ms *
      [[ Forall (fun e => e < length d) al ]]
    POST RET:ms' exists na',
      rep xp F (Synced na' (vssync_vecs d al)) ms'
    CRASH
      exists ms' na',
      rep xp F (Synced na' d) ms' \/
      exists n,
      rep xp F (Synced na' (vssync_vecs d (firstn n al))) ms'
    >} dsync_vecs xp al ms.
  Proof.
    unfold dsync_vecs, rep, rep_inner, synced_rep, map_replay.
    step.
    subst; erewrite <- replay_disk_length; eauto.

    step.
    rewrite vssync_vecs_length; auto.
    apply map_valid_vssync_vecs; auto.
    apply replay_disk_vssync_vecs_comm.

    (* crashes *)
    eassign (mk_memstate (MSInLog ms) cs').
    or_r; cancel.
    rewrite vssync_vecs_length; auto.
    apply map_valid_vssync_vecs; auto.
    apply replay_disk_vssync_vecs_comm.
  Qed.



  Lemma possible_crash_vssync_vecs_listupd : forall F st d l m x,
    (F * arrayN st (vssync_vecs d l))%pred m ->
    possible_crash m x ->
    possible_crash (listupd m st d)  x.
  Proof.
    unfold possible_crash; intuition.
    specialize (H0 a).
    destruct (listupd_sel_cases d a st m ($0, nil)).
    destruct a0; denote listupd as Hx; rewrite Hx; intuition.

    intuition; denote listupd as Hx; rewrite Hx.
    eapply arrayN_selN with (a := a) (def := ($0, nil)) in H; try congruence.
    rewrite vssync_vecs_length; auto.
    eapply arrayN_selN with (a := a) (def := ($0, nil)) in H; auto.
    right; repeat deex; repeat eexists; eauto.
    rewrite H in H2; inversion H2; clear H2; subst.
    denote vsmerge as Hy.
    destruct (In_dec addr_eq_dec (a - st) l).
    rewrite vssync_vecs_selN_In in Hy; simpl in *; intuition.
    rewrite vssync_selN_not_in in Hy; auto.
    rewrite vssync_vecs_length; auto.
  Qed.


  Theorem dsync_vecs_ok: forall xp al ms,
    {< F d na,
    PRE
      rep xp F (Synced na d) ms *
      [[ Forall (fun e => e < length d) al ]]
    POST RET:ms' exists na',
      rep xp F (Synced na' (vssync_vecs d al)) ms'
    XCRASH exists na' ms',
      rep xp F (Synced na' d) ms'
    >} dsync_vecs xp al ms.
  Proof.
    unfold dsync_vecs, rep, rep_inner, synced_rep, map_replay.
    step.
    subst; erewrite <- replay_disk_length; eauto.

    step.
    rewrite vssync_vecs_length; auto.
    apply map_valid_vssync_vecs; auto.
    apply replay_disk_vssync_vecs_comm.

    denote crash_xform as Hx.
    eapply pimpl_trans; [ | eapply Hx ]; cancel.
    xform; cancel.
    repeat (rewrite crash_xform_exists_comm; cancel).
    rewrite crash_xform_sep_star_dist, crash_xform_lift_empty; cancel.
    eassign (mk_memstate (MSInLog ms) (BUFCACHE.cache0 (CSMaxCount x0))).
    simpl; rewrite <- BUFCACHE.crash_xform_rep_r; [ eauto | ].

    eassign (listupd d' (DataStart xp) dummy0).
    eapply possible_crash_vssync_vecs_listupd; eauto.
    denote (sep_star _ _ d') as Hy.
    eapply (arrayN_listupd dummy0) in Hy.
    pred_apply; cancel.
    rewrite vssync_vecs_length; auto.
    Unshelve. all: eauto.
  Qed.


  Hint Extern 1 ({{_}} progseq (dwrite_vecs _ _ _) _) => apply dwrite_vecs_ok : prog.
  Hint Extern 1 ({{_}} progseq (dsync_vecs _ _ _) _) => apply dsync_vecs_ok : prog.





  (****************** crash and recovery *)

  Lemma map_valid_replay_mem_synced_list : forall x0 x3 x4 l',
    map_valid x0 x4 ->
    possible_crash_list x4 l' ->
    Map.Equal x0 (replay_mem x3 vmap0) ->
    map_valid (replay_mem x3 vmap0) (synced_list l').
  Proof.
    intros.
    eapply map_valid_equal; eauto.
    eapply length_eq_map_valid; eauto.
    rewrite synced_list_length.
    erewrite <- possible_crash_list_length; eauto.
  Qed.

  Hint Rewrite selN_combine repeat_selN' Nat.min_id synced_list_length : lists.

  Ltac simplen_rewrite H := try progress (
    set_evars_in H; (rewrite_strat (topdown (hints lists)) in H); subst_evars;
      [ try simplen_rewrite H | try autorewrite with lists .. ]).

  Ltac simplen' := repeat match goal with
    | [H : context[length ?x] |- _] => progress ( first [ is_var x | simplen_rewrite H ] )
    | [H : length ?l = _  |- context [ length ?l ] ] => setoid_rewrite H
    | [H : context[Nat.min ?a ?a] |- _ ] => rewrite Nat.min_id in H
    | [H : ?l = _  |- context [ ?l ] ] => setoid_rewrite H
    | [H : ?l = _ , H2 : context [ ?l ] |- _ ] => rewrite H in H2
    | [H : @length ?T ?l = 0 |- context [?l] ] => replace l with (@nil T) by eauto
    | [H : equal_unless_in _ _ _ |- _ ] => apply equal_unless_in_length_eq in H
    | [H : possible_crash_list _ _ |- _ ] => apply possible_crash_list_length in H
    | [ |- _ < _ ] => try solve [eapply lt_le_trans; eauto; try omega ]
    end.

  Ltac simplen :=  auto; repeat (try subst; simpl;
    auto; simplen'; autorewrite with lists); simpl; eauto; try omega.

  Ltac map_rewrites :=
    match goal with
    | [ H : Map.Equal (replay_mem ?x ?y) _ |- map_valid (replay_mem ?x ?y) ?l ] =>
        eapply (map_valid_equal (MapFacts.Equal_sym H))
    | [ H : Map.Equal _ (replay_mem ?x ?y) |- map_valid (replay_mem ?x ?y) ?l ] =>
        eapply (map_valid_equal H)
    | [ H : Map.Equal _  (replay_mem ?x ?y)
        |-  context [ replay_disk (Map.elements (replay_mem ?x ?y)) _ ] ] =>
        rewrite (mapeq_elements (MapFacts.Equal_sym H))
    | [ H : Map.Equal (replay_mem ?x ?y) _
        |-  context [ replay_disk (Map.elements (replay_mem ?x ?y)) _ ] ] =>
        rewrite (mapeq_elements H)
    end.

  Ltac t :=
    repeat map_rewrites;
    try match goal with
      | [ H : goodSize _ ?a |- goodSize _ ?b ] => simplen
      | [ H : map_valid ?a _ |- map_valid ?a _ ] =>
          solve [ eapply (length_eq_map_valid _ H); simplen ]
      | [ |- map_valid (replay_mem _ _) (synced_list _) ] =>
          try solve [ eapply map_valid_replay_mem_synced_list; eauto ]
    end.

  Lemma equal_unless_in_possible_crash : forall l a b c,
    equal_unless_in l (synced_list a) b ->
    possible_crash_list b c ->
    forall i, ~ In i l -> selN a i $0 = selN c i $0.
  Proof.
    unfold equal_unless_in, possible_crash_list, synced_list.
    intros; simpl in *; autorewrite with lists in *; intuition.
    destruct (lt_dec i (length b)).

    destruct (H4 i l0).
    rewrite <- H0.
    rewrite <- H3 by auto.
    rewrite selN_combine; simplen.

    contradict H0.
    rewrite <- H3 by auto.
    rewrite selN_combine by simplen; simpl.
    rewrite repeat_selN; simplen.
    repeat rewrite selN_oob; simplen.
  Qed.

  Lemma equal_unless_in_updN : forall B l a (b : B) v d d',
    ~ KIn (a, b) l ->
    equal_unless_in (a :: map fst l) d d' ->
    equal_unless_in (map fst l) (updN d a (v, nil)) (updN d' a (v, nil)).
  Proof.
    unfold equal_unless_in, synced_list; intuition; simpl in *.
    simplen.
    destruct (lt_dec a0 (length d)).
    destruct (Nat.eq_dec a a0); simplen.
    repeat rewrite selN_updN_ne by auto.
    rewrite <- H2; simplen; tauto.
    repeat rewrite selN_oob; simplen.
  Qed.

  Lemma equal_unless_in_sym : forall l a b,
    equal_unless_in l a b <-> equal_unless_in l b a.
  Proof.
    unfold equal_unless_in; firstorder.
  Qed.

  Lemma equal_unless_in_replay_disk' : forall l a b,
    KNoDup l ->
    equal_unless_in (map fst l) a b ->
    replay_disk l a = replay_disk l b.
  Proof.
    induction l; intuition; simpl.
    eapply list_selN_ext; intros.
    simplen.
    apply H0; auto.

    inversion H; simpl in *; subst.
    eapply IHl; auto.
    eapply equal_unless_in_updN; eauto.
  Qed.

  Lemma equal_unless_in_replay_disk : forall a b m,
    equal_unless_in (map_keys m) b a ->
    replay_disk (Map.elements m) a = replay_disk (Map.elements m) b.
  Proof.
    intros.
    eapply equal_unless_in_replay_disk'; eauto.
    apply equal_unless_in_sym; auto.
  Qed.

  Lemma list2nmem_replay_disk_crash_xform : forall ents vsl vl (F : rawpred),
    KNoDup ents ->
    possible_crash_list vsl vl ->
    F (list2nmem (replay_disk ents vsl)) ->
    crash_xform F (list2nmem (replay_disk ents (synced_list vl))).
  Proof.
    induction ents; simpl; intros.
    eapply list2nmem_crash_xform; eauto.
    inversion H; destruct a; simpl in *; subst.
    rewrite synced_list_updN.
    eapply IHents; eauto.
    apply possible_crash_list_updN; auto.
  Qed.

  Lemma map_valid_replay_mem_app : forall a ents l' x0 x1,
     Map.Equal x0 (replay_mem a vmap0) ->
     map_valid x0 x1 ->
     possible_crash_list x1 l' ->
     log_valid ents (replay_disk (Map.elements (elt:=valu) x0) x1) ->
     map_valid (replay_mem (a ++ ents) vmap0) (synced_list l').
  Proof.
      intros.
      eapply map_valid_equal.
      apply MapFacts.Equal_sym.
      apply replay_mem_app; auto.
      apply MapFacts.Equal_refl.
      apply map_valid_replay_mem'.
      destruct H2; split; intros; auto.
      specialize (H3 _ _ H4); destruct H3.
      simplen.
      eapply map_valid_equal; eauto.
      unfold map_valid; intros.
      destruct (H0 _ _ H3); simplen.
  Qed.



  Definition recover_either_pred xp Fold Fnew :=
    (exists ms d ents,
       ( exists na, rep_inner xp (Synced na d) ms *
          [[[ d ::: Fold ]]] )
     \/( exists na, rep_inner xp (Synced na (replay_disk ents d)) ms *
          [[[ replay_disk ents d ::: Fnew ]]] )
     \/ rep_inner xp (Flushing d ents) ms *
          [[[ d ::: Fold ]]] *
          [[[ replay_disk ents d ::: Fnew ]]]
     \/ rep_inner xp (Applying d) ms *
          [[[ d ::: Fold ]]]
      )%pred.

  Definition after_crash_pred xp Fold Fnew:=
    (exists na ms d, 
      rep_inner xp (Synced na d) ms *
      ([[[ d ::: crash_xform Fold ]]] \/ [[[ d ::: crash_xform Fnew ]]])
    )%pred.


  Hint Rewrite crash_xform_arrayN
    DLog.xform_rep_synced  DLog.xform_rep_truncated
    DLog.xform_rep_extended DLog.xform_rep_extended_unsync: crash_xform.

  Local Hint Resolve MapFacts.Equal_refl map_valid_replay_mem_synced_list.

  Lemma recover_either_after_crash : forall xp Fold Fnew,
    crash_xform (recover_either_pred xp Fold Fnew) =p=>
    after_crash_pred xp Fold Fnew.
  Proof.
    unfold recover_either_pred, after_crash_pred, rep_inner,
           map_replay, synced_rep, unsync_rep; intros.
    repeat progress (xform; norml; unfold stars; simpl; clear_norm_goal);
       cancel; t.

    (* Synced d *)
    or_l; cancel; t.
    eapply list2nmem_replay_disk_crash_xform; eauto.

    (* Synced (replay_disk ents d) *)
    or_r; cancel; t.
    eapply list2nmem_replay_disk_crash_xform; eauto.
    rewrite <- H3; auto.

    (* Flushing d ents :: ExtendedUnsync d *)
    or_l; cancel.
    eapply list2nmem_replay_disk_crash_xform; eauto.
    (* Flushing d ents :: Extended d *)
    or_l; cancel.
    eapply list2nmem_replay_disk_crash_xform; eauto.
    (* Flushing d ents :: Synced (replay_disk ents d) *)
    or_r; cancel.
    eapply list2nmem_replay_disk_crash_xform; eauto.
    setoid_rewrite mapeq_elements.
    2: apply replay_mem_app; eauto.
    rewrite <- replay_disk_replay_mem; auto.
    eapply map_valid_replay_mem_app; eauto.

    (* Applying d :: unsync *)
    or_l; cancel.
    eapply list2nmem_replay_disk_crash_xform; eauto.
    erewrite equal_unless_in_replay_disk; eauto.
    eapply map_valid_equal; eauto.
    eapply length_eq_map_valid; eauto; simplen.

    (* Applying d :: synced *)
    or_l; cancel.
    eapply list2nmem_replay_disk_crash_xform; eauto.
    rewrite replay_disk_twice; auto.
    eapply map_valid_equal; eauto.
    eapply length_eq_map_valid; eauto; simplen.

    (* Applying d :: Truncated *)
    or_l; cancel.
    eapply list2nmem_crash_xform; eauto.
    apply map_valid_map0.
  Qed.

  Remove Hints MapFacts.Equal_refl.

  Lemma recover_either_after_crash_unfold : forall xp F Fold Fnew,
    crash_xform (F * recover_either_pred xp Fold Fnew)
      =p=>
    crash_xform F * exists na ms log old new,
       synced_rep xp old * DLog.rep xp (DLog.Synced na log) *
       [[ new = replay_disk (Map.elements ms) old ]] *
       [[ Map.Equal ms (replay_mem log vmap0) ]] *
       [[ goodSize addrlen (length old) /\ map_valid ms old ]] *
       ([[[ new ::: crash_xform Fold ]]] \/ [[[ new ::: crash_xform Fnew ]]]).
  Proof.
    intros; xform.
    rewrite recover_either_after_crash.
    unfold after_crash_pred, rep, rep_inner, map_replay.
    cancel_with eauto.
    or_l; cancel.
    or_r; cancel.
  Qed.


  Definition recover T xp cs rx : prog T :=
    let^ (cs, log) <- DLog.read xp cs;
    rx (mk_memstate (replay_mem log vmap0) cs).

  Theorem recover_ok: forall xp F cs,
    {< raw Fold Fnew,
    PRE
      BUFCACHE.rep cs raw *
      [[ crash_xform (F * recover_either_pred xp Fold Fnew)%pred raw ]]
    POST RET:ms'
      exists na d', rep xp (crash_xform F) (Synced na d') ms' *
      ([[[ d' ::: crash_xform Fold ]]] \/ [[[ d' ::: crash_xform Fnew ]]])
    CRASH exists cs',
      BUFCACHE.rep cs' raw
    >} recover xp cs.
  Proof.
    unfold recover; intros.
    prestep; xform.
    norml.

    (* manually get two after-crash cases *)
    apply recover_either_after_crash_unfold in H4.
    destruct_lifts.
    apply sep_star_or_distr in H0; apply pimpl_or_apply in H0.
    destruct H0; destruct_lift H0.

    (* case 1 : last transaction unapplied *)
    - cancel.
      step.
      unfold rep; cancel.
      or_l; cancel; eauto.

      unfold rep_inner, map_replay.
      cancel; try map_rewrites; auto.
      eapply map_valid_equal; eauto.
      pimpl_crash; cancel.

    (* case 2 : last transaction applied *)
    - cancel.
      step.
      unfold rep; cancel.
      or_r; cancel; eauto.

      unfold rep_inner, map_replay, synced_rep.
      cancel; try map_rewrites; auto.
      eapply map_valid_equal; eauto.
      pimpl_crash; cancel.
  Qed.


  Hint Extern 1 ({{_}} progseq (read _ _ _) _) => apply read_ok : prog.
  Hint Extern 1 ({{_}} progseq (flush _ _ _) _) => apply flush_ok : prog.
  Hint Extern 1 ({{_}} progseq (dwrite _ _ _ _) _) => apply dwrite_ok : prog.
  Hint Extern 1 ({{_}} progseq (dsync _ _ _) _) => apply dsync_ok : prog.
  Hint Extern 1 ({{_}} progseq (recover _ _) _) => apply recover_ok : prog.


End MLog.