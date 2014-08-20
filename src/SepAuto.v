Require Import Arith.
Require Import Omega.
Require Import List.
Require Import Prog.
Require Import Pred.
Require Import Hoare.

Set Implicit Arguments.


(** * Separation logic proof automation *)

Definition stars (ps : list pred) :=
  fold_left sep_star ps emp.

Ltac sep_imply'' H := eapply pimpl_apply; [ | apply H ].

Ltac sep_imply' m :=
  match goal with
  | [ H : _ m |- _ ] => sep_imply'' H
  | [ H : _ _ m |- _ ] => sep_imply'' H
  | [ H : _ _ _ m |- _ ] => sep_imply'' H
  end.

Ltac sep_imply :=
  match goal with
  | [ |- _ ?m ] => sep_imply' m
  | [ |- _ _ ?m ] => sep_imply' m
  | [ |- _ _ _ ?m ] => sep_imply' m
  end.

Theorem start_normalizing : forall PT QT p q ps qs P Q,
  p <==> (exists (x:PT), stars (ps x) * [[P x]])%pred
  -> q <==> (exists (x:QT), stars (qs x) * [[Q x]])%pred
  -> ((exists (x:PT), stars (ps x) * stars nil * [[P x]]) ==>
      (exists (x:QT), stars (qs x) * [[Q x]]))
  -> p ==> q.
Proof.
  unfold stars; simpl; intros.
  eapply pimpl_trans; [apply H|].
  eapply pimpl_exists_l; intro eP.
  eapply pimpl_trans; [eapply pimpl_trans; [|apply H1]|].
  eapply pimpl_exists_r; exists eP.
  eapply pimpl_trans; [apply pimpl_star_emp|].
  eapply pimpl_trans; [apply sep_star_assoc|].
  apply piff_star_r. apply sep_star_comm.
  eapply pimpl_exists_l; intro eQ.
  eapply pimpl_trans; [|apply H0].
  eapply pimpl_exists_r; exists eQ.
  apply pimpl_refl.
Qed.

Theorem restart_canceling:
  forall p q,
  (stars p * stars nil ==> stars q) ->
  (stars nil * stars p ==> stars q).
Proof.
  intros; eapply pimpl_trans; [ eapply sep_star_comm | eauto ].
Qed.

Lemma stars_prepend':
  forall l x,
  fold_left sep_star l x <==> x * fold_left sep_star l emp.
Proof.
  induction l.
  - simpl. intros.
    eapply piff_trans.
    apply emp_star.
    apply sep_star_comm.
  - simpl. intros.
    eapply piff_trans.
    eapply IHl.
    eapply piff_trans.
    eapply sep_star_assoc.
    eapply piff_star_l.
    eapply piff_comm.
    eapply piff_trans.
    eapply IHl.
    eapply piff_comm.
    eapply piff_trans.
    eapply emp_star.
    eapply piff_comm.
    eapply piff_trans.
    eapply sep_star_assoc.
    eapply piff_refl.
Qed.

Lemma stars_prepend:
  forall l x,
  stars (x :: l) <==> x * stars l.
Proof.
  unfold stars; simpl; intros.
  eapply piff_trans. apply stars_prepend'.
  eapply piff_trans. apply sep_star_assoc.
  apply piff_comm. apply emp_star.
Qed.

Lemma flatten_default' : forall p,
  p <==> stars (p :: nil).
Proof.
  unfold stars; apply emp_star.
Qed.

Lemma flatten_default : forall p,
  p <==> exists (x:unit), stars (p :: nil) * [[True]].
Proof.
  unfold stars; split.
  - apply pimpl_exists_r; exists tt.
    apply sep_star_lift_r.
    split; pred. apply pimpl_star_emp; auto.
  - apply pimpl_exists_l; intros.
    eapply pimpl_trans; [apply sep_star_lift2and|].
    eapply pimpl_trans; [|apply star_emp_pimpl].
    firstorder.
Qed.

Lemma flatten_emp' : emp <==> stars nil.
Proof.
  firstorder.
Qed.

Lemma flatten_emp :
  emp <==> exists (x:unit), stars nil * [[True]].
Proof.
  split.
  - apply pimpl_exists_r; exists tt.
    apply sep_star_lift_r.
    firstorder.
  - apply pimpl_exists_l; intros.
    eapply pimpl_trans; [apply sep_star_lift2and|].
    firstorder.
Qed.

Lemma flatten_star' : forall p q ps qs,
  p <==> stars ps
  -> q <==> stars qs
  -> p * q <==> stars (ps ++ qs).
Proof.
  intros.
  eapply piff_trans; [eapply piff_star_r; apply H|]; clear H.
  eapply piff_trans; [eapply piff_star_l; apply H0|]; clear H0.
  induction ps.
  - eapply piff_trans; [apply piff_comm; apply emp_star|apply piff_refl].
  - apply piff_comm.
    eapply piff_trans; [apply stars_prepend|].
    eapply piff_trans; [apply piff_star_l; apply piff_comm; apply IHps|].
    eapply piff_trans; [apply piff_comm; apply sep_star_assoc|].
    apply piff_star_r.
    apply piff_comm.
    eapply piff_trans; [eapply stars_prepend|].
    apply piff_refl.
Qed.

Lemma flatten_star : forall PT QT p q ps qs P Q,
  p <==> (exists (x:PT), stars (ps x) * [[P x]])%pred
  -> q <==> (exists (x:QT), stars (qs x) * [[Q x]])%pred
  -> p * q <==> exists (x:PT*QT), stars (ps (fst x) ++ qs (snd x)) * [[P (fst x) /\ Q (snd x)]].
Proof.
  intros.
  eapply piff_trans; [eapply piff_star_r; apply H|]; clear H.
  eapply piff_trans; [eapply piff_star_l; apply H0|]; clear H0.
  split.
  - apply pimpl_exists_l_star. apply pimpl_exists_l. intro ePT.
    eapply pimpl_trans; [apply sep_star_comm|].
    apply pimpl_exists_l_star. apply pimpl_exists_l. intro eQT.
    apply pimpl_exists_r. exists (ePT, eQT). simpl.
    eapply pimpl_trans; [apply sep_star_assoc_2|].
    apply sep_star_lift_l; intros.
    eapply pimpl_trans; [apply sep_star_comm|].
    eapply pimpl_trans; [apply sep_star_assoc_2|].
    apply sep_star_lift_l; intros.
    apply sep_star_lift_r.
    apply pimpl_and_split; [|firstorder].
    apply flatten_star'; apply piff_refl.
  - apply pimpl_exists_l. intro e. simpl.
    eapply pimpl_trans; [|apply pimpl_exists_r_star].
    apply pimpl_exists_r. exists (fst e).
    eapply pimpl_trans; [|apply sep_star_comm].
    eapply pimpl_trans; [|apply pimpl_exists_r_star].
    apply pimpl_exists_r. exists (snd e).
    apply sep_star_lift_l; intros.
    eapply pimpl_trans; [|apply sep_star_assoc_1].
    apply sep_star_lift_r.
    apply pimpl_and_split; [|firstorder].
    eapply pimpl_trans; [|apply sep_star_comm].
    eapply pimpl_trans; [|apply sep_star_assoc_1].
    apply sep_star_lift_r.
    apply pimpl_and_split; [|firstorder].
    apply flatten_star'; apply piff_refl.
Qed.

Lemma flatten_exists: forall T PT p ps P,
  (forall (a:T), (p a <==> exists (x:PT), stars (ps a x) * [[P a x]]))
  -> (exists (a:T), p a) <==>
      (exists (x:(T*PT)), stars (ps (fst x) (snd x)) * [[P (fst x) (snd x)]]).
Proof.
  intros; split.
  - apply pimpl_exists_l; intro eT.
    eapply pimpl_trans; [apply H|].
    apply pimpl_exists_l; intro ePT.
    apply pimpl_exists_r. exists (eT, ePT).
    apply pimpl_refl.
  - apply pimpl_exists_l; intro e.
    apply pimpl_exists_r. exists (fst e).
    eapply pimpl_trans; [|apply H].
    apply pimpl_exists_r. exists (snd e).
    apply pimpl_refl.
Qed.

Lemma flatten_lift_empty: forall P,
  [[P]] <==> (exists (x:unit), stars nil * [[P]]).
Proof.
  split.
  - apply pimpl_exists_r. exists tt. apply emp_star.
  - apply pimpl_exists_l; intros. apply emp_star.
Qed.

Ltac flatten := repeat match goal with
                       | [ |- emp <==> _ ] => apply flatten_emp
                       | [ |- _ * _ <==> _ ] =>
                         eapply piff_trans; [ apply flatten_star | apply piff_refl ]
                       | [ |- (exists _, _)%pred <==> _ ] =>
                         eapply piff_trans; [ apply flatten_exists | apply piff_refl ]; intros
                       | [ |- [[_]] <==> _ ] =>
                         eapply piff_trans; [ apply flatten_lift_empty | apply piff_refl ]
                       | _ => apply flatten_default
                       end.

Definition okToUnify (p1 p2 : pred) := p1 = p2.

Hint Extern 1 (okToUnify (?p |-> _) (?p |-> _)) => constructor : okToUnify.
Hint Extern 1 (okToUnify ?a ?a) => constructor : okToUnify.

(* Try to unify any two [ptsto] predicates.  Since omega does not unify
 * existential variables, this is safe to do; they will be unified only
 * if the addresses in the two [ptsto] predicates are necessarily equal.
 *)
Hint Extern 1 (okToUnify (?a |-> _) (?b |-> _)) =>
  unfold okToUnify; f_equal; omega : okToUnify.

Inductive pick (lhs : pred) : list pred -> list pred -> Prop :=
| PickFirst : forall p ps,
  okToUnify lhs p
  -> pick lhs (p :: ps) ps
| PickLater : forall p ps ps',
  pick lhs ps ps'
  -> pick lhs (p :: ps) (p :: ps').

Ltac pick := solve [ repeat ((apply PickFirst; solve [ auto with okToUnify ])
                               || apply PickLater) ].

Theorem imply_one : forall qs qs' p q ps F,
  (pick q qs qs' /\ (p ==> q))
  -> (stars ps * F ==> stars qs')
  -> stars (p :: ps) * F ==> stars qs.
Proof.
  intros. destruct H.
  eapply pimpl_trans. eapply pimpl_sep_star. apply stars_prepend. apply pimpl_refl.
  eapply pimpl_trans. apply sep_star_assoc_1.
  eapply pimpl_trans. eapply pimpl_sep_star. eauto. eauto.
  clear dependent ps.
  induction H; intros.
  - inversion H; subst. apply stars_prepend.
  - eapply pimpl_trans; [|apply stars_prepend].
    eapply pimpl_trans; [|eapply pimpl_sep_star; [apply pimpl_refl|apply IHpick] ].
    eapply pimpl_trans. eapply pimpl_sep_star. eapply pimpl_refl. eapply stars_prepend.
    eapply pimpl_trans; [eapply sep_star_assoc_2|].
    eapply pimpl_trans; [|eapply sep_star_assoc_1].
    eapply pimpl_sep_star. eapply sep_star_comm. eapply pimpl_refl.
Qed.

Theorem cancel_one : forall qs qs' p ps F,
  pick p qs qs'
  -> (stars ps * F ==> stars qs')
  -> stars (p :: ps) * F ==> stars qs.
Proof.
  intros.
  eapply imply_one; eauto.
Qed.

Ltac cancel_one := eapply cancel_one; [ pick | ].

Theorem delay_one : forall p ps q qs,
  (stars ps * stars (p :: qs) ==> q)
  -> stars (p :: ps) * stars qs ==> q.
Proof.
  unfold stars; simpl; intros.
  eapply pimpl_trans; [|eauto].
  eapply pimpl_trans. eapply pimpl_sep_star; [|eapply pimpl_refl]. apply stars_prepend.
  eapply pimpl_trans; [|eapply pimpl_sep_star; [apply pimpl_refl|apply stars_prepend] ].
  eapply pimpl_trans; [|eapply sep_star_assoc_1].
  eapply pimpl_sep_star; [|eapply pimpl_refl].
  eapply sep_star_comm.
Qed.

Ltac delay_one := apply delay_one.

Lemma and_imp:
  forall (A B C:Prop),
  (A -> B)
  -> (A /\ C)
  -> (B /\ C).
Proof.
  firstorder.
Qed.

Ltac pick_imply_this :=
  split; [ apply PickFirst; apply eq_refl | solve [ eauto with imply ] ].
Ltac pick_imply_next := eapply and_imp; [apply PickLater|].
Ltac pick_imply := solve [ repeat (pick_imply_this || pick_imply_next) ].
Ltac imply_one := eapply imply_one ; [ pick_imply | ].

Lemma finish_frame : forall p,
  stars nil * p ==> stars (p :: nil).
Proof.
  unfold stars. intros. apply pimpl_refl.
Qed.

Lemma finish_easier : forall p,
  stars nil * p ==> p.
Proof.
  unfold stars. apply emp_star.
Qed.

Ltac cancel' := repeat (cancel_one || delay_one);
                eapply restart_canceling;
                repeat (imply_one || delay_one);
                try (apply finish_frame || apply finish_easier).

Lemma stars_or_left: forall a b c,
  (a ==> stars (b :: nil))
  -> (a ==> stars ((b \/ c) :: nil)).
Proof.
  unfold stars; simpl; intros.
  eapply pimpl_trans; [|apply pimpl_star_emp].
  apply pimpl_or_r. left.
  eapply pimpl_trans; [|apply star_emp_pimpl].
  eauto.
Qed.

Lemma stars_or_right: forall a b c,
  (a ==> stars (c :: nil))
  -> (a ==> stars ((b \/ c) :: nil)).
Proof.
  unfold stars; simpl; intros.
  eapply pimpl_trans; [|apply pimpl_star_emp].
  apply pimpl_or_r. right.
  eapply pimpl_trans; [|apply star_emp_pimpl].
  eauto.
Qed.

Ltac destruct_prod := match goal with
                      | [ H: (?a * ?b)%type |- _ ] => destruct H
                      | [ H: unit |- _ ] => clear H
                      end.

Ltac destruct_and := match goal with
                     | [ H: ?a /\ ?b |- _ ] => destruct H
                     | [ H: True |- _ ] => clear H
                     end.

Lemma eexists_pair: forall A B p,
  (exists (a:A) (b:B), p (a, b))
  -> (exists (e:A*B), p e).
Proof.
  intros.
  destruct H as [a H].
  destruct H as [b H].
  exists (a, b); auto.
Qed.

Ltac eexists_one :=
  match goal with
  | [ |- exists (_:unit), _ ] => exists tt
  | [ |- exists (_:(_*_)), _ ] => apply eexists_pair
  | [ |- exists _, _ ] => eexists
  end.

Ltac norm_or_l := match goal with
                  | [ |- _ \/ _ ==> _ ] => apply pimpl_or_l
                  end.

Ltac norm'l := eapply start_normalizing; [ flatten | flatten | ];
               eapply pimpl_exists_l; intros;
               apply sep_star_lift_l; intros;
               repeat destruct_prod;
               repeat destruct_and;
               simpl in *.

Ltac norm'r := eapply pimpl_exists_r; repeat eexists_one;
               apply sep_star_lift_r; apply pimpl_and_lift;
               simpl in *.

Ltac norm_hint h := repeat norm_or_l; norm'l; try h; try norm'r.
Ltac norm := norm_hint idtac.

Ltac cancel_hint h :=
  unfold stars; simpl;
  norm_hint h; intuition;
  try match goal with
      | [ |- _ ==> stars ((_ \/ _) :: nil) ] =>
        solve [ apply stars_or_left; cancel_hint h
              | apply stars_or_right; cancel_hint h ]
      | [ |- _ ==> _ ] => cancel'
      end;
  unfold stars; simpl.
Ltac cancel := cancel_hint idtac.

Ltac step_hint h :=
  intros;
  try cancel_hint h;
  ((eapply pimpl_ok; [ solve [ eauto with prog ] | ])
   || (eapply pimpl_ok_cont; [ solve [ eauto with prog ] | | ]));
  try ( cancel_hint h ; try ( progress autorewrite with core in * ; cancel_hint h ) );
  intuition eauto;
  try omega;
  eauto.
Ltac step := step_hint idtac.

Ltac hoare_hint h := repeat step_hint h.
Ltac hoare := hoare_hint idtac.
