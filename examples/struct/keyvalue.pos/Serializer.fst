module Serializer

open FStar.Seq
open FStar.HyperStack
open FStar.HyperStack.ST
module B = FStar.Buffer
module U16 = FStar.UInt16
module U32 = FStar.UInt32

open KeyValue
open Slice
open PureEncoder

(*! Efficient serializing *)

(* NOTE: I'm using ser out of laziness, but they should NOT be abbreviated, we
can serialize everywhere *)

let offset_into (buf:bslice) = off:U32.t{U32.v off <= U32.v buf.len}

let serialized (enc:bytes) (buf:bslice) (r:option (offset_into buf)) (h0 h1:mem) :
    Pure Type0
    (requires (live h1 buf))
    (ensures (fun _ -> True)) =
    match r with
    | Some off ->
      let (b1, b2) = bslice_split_at buf off in
      modifies_slice b1 h0 h1 /\
      as_seq h1 b1 == enc
    | None ->
      modifies_slice buf h0 h1

let buffer_fun (inputs:TSet.set bslice) =
    f:(h:mem{forall b. TSet.mem b inputs ==> live h b} -> GTot bytes){
      forall (h0 h1: h:mem{forall b. TSet.mem b inputs ==> live h b}).
      (forall b. TSet.mem b inputs ==> as_seq h0 b == as_seq h1 b) ==>
      f h0 == f h1}

let disjoint_in (h:mem) (inputs:TSet.set bslice) (buf:bslice) =
  forall b. TSet.mem b inputs ==> live h b /\ B.disjoint b.p buf.p

inline_for_extraction unfold
let serializer_any (inputs:TSet.set bslice)
                   (enc: buffer_fun inputs) =
  buf:bslice ->
  ST (option (off:offset_into buf))
     (requires (fun h0 -> live h0 buf /\
                       disjoint_in h0 inputs buf))
     (ensures (fun h0 r h1 ->
        live h0 buf /\
        live h1 buf /\
        (forall b. TSet.mem b inputs ==>
           live h0 b /\
           live h1 b /\
           as_seq h0 b == as_seq h1 b) /\
        serialized (enc h1) buf r h0 h1))

inline_for_extraction unfold
let serializer (enc:bytes) = serializer_any TSet.empty (fun _ -> enc)

inline_for_extraction unfold
let serializer_1 (input:bslice) (enc: buffer_fun (TSet.singleton input)) =
    serializer_any (TSet.singleton input) (fun h -> enc h)

let lemma_index_upd_gt (#a:Type) (s:Seq.seq a) (n:nat{n < length s}) (i:nat{n < i /\ i < length s}) (v:a) :
  Lemma (index (Seq.upd s n v) i == index s i)
  [SMTPat (index (Seq.upd s n v) i)] = ()

#reset-options "--z3rlimit 10"

val upd_len_1 : #a:Type -> s:Seq.seq a{length s == 1} -> v:a ->
  Lemma (Seq.upd s 0 v == Seq.create 1 v)
let upd_len_1 #a s v =
  lemma_eq_intro (Seq.upd s 0 v) (Seq.create 1 v)

val ser_byte: v:byte -> serializer (Seq.create 1 v)
let ser_byte v = fun buf ->
  if U32.lt buf.len 1ul then None
  else
    let (buf, _) = bslice_split_at buf 1ul in
    let h0 = get() in
    B.upd buf.p 0ul v;
    begin
      let s0 = as_seq h0 buf in
      upd_len_1 s0 v
    end;
    Some 1ul

let upd_len_2 (#a:Type) (s:Seq.seq a{length s == 2}) (vs:Seq.seq a{length vs == 2}) :
  Lemma (Seq.upd (Seq.upd s 0 (index vs 0)) 1 (index vs 1) == vs) =
  lemma_eq_intro (Seq.upd (Seq.upd s 0 (index vs 0)) 1 (index vs 1)) vs

val ser_u16: v:U16.t -> serializer (u16_to_be v)
let ser_u16 v = fun buf ->
  if U32.lt buf.len 2ul then None
  else
    let bs = u16_to_be v in
    let (buf, _) = bslice_split_at buf 2ul in
    let h0 = get() in
    B.upd buf.p 0ul (index bs 0);
    B.upd buf.p 1ul (index bs 1);
    begin
      let s0 = as_seq h0 buf in
      upd_len_2 s0 bs
    end;
    Some 2ul

let upd_len_4 (#a:Type) (s:Seq.seq a{length s == 4}) (vs:Seq.seq a{length vs == 4}) :
  Lemma (Seq.upd
          (Seq.upd
            (Seq.upd
              (Seq.upd s 0 (index vs 0))
            1 (index vs 1))
          2 (index vs 2))
        3 (index vs 3) == vs) =
  lemma_eq_intro (Seq.upd
  (Seq.upd
  (Seq.upd
  (Seq.upd s 0 (index vs 0))
  1 (index vs 1))
  2 (index vs 2))
  3 (index vs 3)) vs

val ser_u32: v:U32.t -> serializer (u32_to_be v)
let ser_u32 v = fun buf ->
  if U32.lt buf.len 4ul then None
  else
    let bs = u32_to_be v in
    let (buf, _) = bslice_split_at buf 4ul in
    let h0 = get() in
    B.upd buf.p 0ul (index bs 0);
    B.upd buf.p 1ul (index bs 1);
    B.upd buf.p 2ul (index bs 2);
    B.upd buf.p 3ul (index bs 3);
    begin
      let s0 = as_seq h0 buf in
      upd_len_4 s0 bs
    end;
    Some 4ul

// this is really a coercion that lifts a pure bytes serializer to one that
// takes an input buffer (and ignores it)
// this is a higher-order combinator that needs to be inlined
inline_for_extraction [@"substitute"]
let ser_input (input:bslice) (#b:bytes) (s:serializer b) : serializer_1 input (fun _ -> b) =
    fun buf -> s buf

// coercion to increase the size of the inputs set
// this is a higher-order combinator that needs to be inlined
inline_for_extraction [@"substitute"]
let ser_inputs (#inputs1:TSet.set bslice)
               (inputs2:TSet.set bslice{TSet.subset inputs1 inputs2})
               (#b: buffer_fun inputs1)
               (s:serializer_any inputs1 b) : serializer_any inputs2 (fun h -> b h) =
    fun buf -> s buf

#reset-options "--z3rlimit 30"

// this is a higher-order combinator that needs to be inlined
inline_for_extraction [@"substitute"]
let ser_append (#inputs1 #inputs2:TSet.set bslice)
               (#b1: buffer_fun inputs1) (#b2: buffer_fun inputs2)
               (s1:serializer_any inputs1 b1) (s2:serializer_any inputs2 b2) :
               serializer_any (TSet.union inputs1 inputs2) (fun h -> append (b1 h) (b2 h)) =
  fun buf ->
  let h0 = get() in
  match s1 buf with
  | Some off ->
    begin
      let h1 = get() in
      let buf0 = buf in
      let (buf1, buf) = bslice_split_at buf off in
      match s2 buf with
      | Some off' -> (if u32_add_overflows off off' then None
                     else begin
                      begin
                        let h2 = get() in
                        let (buf2, buf3) = bslice_split_at buf off' in
                        let (buf12, buf3') = bslice_split_at buf0 (U32.add off off') in
                        assert (live h2 buf12);
                        assert (as_seq h2 buf2 == b2 h2);
                        assert (as_seq h2 buf1 == b1 h2);
                        is_concat_append buf12.p buf1.p buf2.p h2;
                        assert (as_seq h2 buf12 == append (b1 h2) (b2 h2));
                        //assert (modifies_slice buf1 h0 h1);
                        //assert (modifies_slice buf2 h1 h2);
                        modifies_grow_from_b1 buf12 buf1 buf2 h0 h1;
                        modifies_grow_from_b2 buf12 buf1 buf2 h1 h2;
                        assert (modifies_slice buf12 h0 h2)
                      end;
                      Some (U32.add off off')
                     end)
      | None -> None
    end
  | None -> None

#reset-options

val ser_copy : data:bslice -> serializer_1 data (fun h -> as_seq h data)
let ser_copy data = fun buf ->
  if U32.lt buf.len data.len then None
  else begin
    let (buf1, buf2) = bslice_split_at buf data.len in
    B.blit data.p 0ul buf1.p 0ul data.len;
    Some data.len
  end

let enc_u16_array_st (a: u16_array_st) (h:mem{live h a.a16_st}) : GTot bytes =
    u16_to_be a.len16_st `append` as_seq h a.a16_st

val ser_u16_array : a:u16_array_st ->
  serializer_any (TSet.singleton a.a16_st) (fun h -> enc_u16_array_st a h)
let ser_u16_array a =
  ser_inputs (TSet.singleton a.a16_st)
  (ser_input a.a16_st (ser_u16 a.len16_st) `ser_append`
   ser_copy a.a16_st)

let enc_u32_array_st (a: u32_array_st) (h:mem{live h a.a32_st}) : GTot bytes =
  u32_to_be a.len32_st `append` as_seq h a.a32_st

val ser_u32_array : a:u32_array_st ->
  serializer_any (TSet.singleton a.a32_st) (fun h -> enc_u32_array_st a h)
let ser_u32_array a =
  ser_inputs (TSet.singleton a.a32_st)
  (ser_u32 a.len32_st `ser_append`
   ser_copy a.a32_st)

noextract
val entry_st_bufs : e:entry_st -> TSet.set bslice
noextract
let entry_st_bufs (e: entry_st) = TSet.union (TSet.singleton e.key_st.a16_st) (TSet.singleton e.val_st.a32_st)

val enc_entry_st : e:entry_st -> h:mem{forall b. TSet.mem b (entry_st_bufs e) ==> live h b} -> GTot bytes
let enc_entry_st (e:entry_st) h =
    enc_u16_array_st e.key_st h `append` enc_u32_array_st e.val_st h

let ser_entry (e:entry_st) : serializer_any (entry_st_bufs e) (fun h -> enc_entry_st e h) =
    ser_inputs (entry_st_bufs e)
    (ser_u16_array e.key_st `ser_append` ser_u32_array e.val_st)

(*! Incremental key-value store writer *)

// TODO: will create a complete key-value store by allocating a length field,
// repeatedly calling ser_entry (advancing the output each time), then filling
// in the length

let adjacent_entries_disjoint (#t:Type) (b1 b2:B.buffer t) :
    Lemma (requires (buffers_adjacent b1 b2))
          (ensures (B.disjoint b1 b2)) = ()

// TODO: the writer is tracking a few more pointers than strictly necessary; we
// really only need a pointer to the beginning and a bslice at the current write
// position
noeq type writer =
     { length_field: b:lbuffer 4;
       entries_written_buf: bslice;
       entries_written_list: unit -> GTot (list encoded_entry);
       num_entries_written: U32.t;
       entries_scratch: bslice; }

let writer_valid (w:writer) : Type0 =
    buffers_adjacent w.length_field w.entries_written_buf.p /\
    buffers_adjacent w.entries_written_buf.p w.entries_scratch.p /\
    // so that total size of written data fits in a bslice
    4 + U32.v w.num_entries_written < pow2 32

let writer_inv (h:mem) (w:writer) : Type0 =
    writer_valid w /\
    B.live h w.length_field /\
    B.live h w.entries_scratch.p /\
    (let entries_buf = w.entries_written_buf in
     let enc_entries = as_seq h entries_buf in
     let num_entries = U32.v w.num_entries_written in
     let entries = w.entries_written_list () in
     live h entries_buf /\
     List.length entries == num_entries /\
     enc_entries == encode_many entries encode_entry num_entries)

val adjacent_advance (b:bslice) (off:U32.t{U32.v off <= U32.v b.len}) :
  Lemma (buffers_adjacent (truncated_slice b off).p (advance_slice b off).p)
  [SMTPat (buffers_adjacent (truncated_slice b off).p (advance_slice b off).p)]
let adjacent_advance b off = ()

val adjacent_truncate (b b':bslice) (len:U32.t{U32.v len <= U32.v b'.len}) :
  Lemma (requires (buffers_adjacent b.p b'.p))
        (ensures (buffers_adjacent b.p (truncated_slice b' len).p))
  [SMTPat (buffers_adjacent b.p (truncated_slice b' len).p)]
let adjacent_truncate b b' len = ()

val adjacent_0len (b:bslice) :
    Lemma (buffers_adjacent (truncated_slice b 0ul).p b.p)
    [SMTPat (buffers_adjacent (truncated_slice b 0ul).p b.p)]
let adjacent_0len b = ()

let writer_init (b:bslice) : ST (option writer)
    (requires (fun h0 -> live h0 b))
    (ensures (fun h0 r h1 ->
             h0 == h1 /\
             Some? r ==>
             writer_inv h1 (Some?.v r))) =
    if U32.lt b.len 4ul then None
    else
    let w = { length_field = (truncated_slice b 4ul).p;
              entries_written_buf = truncated_slice (advance_slice b 4ul) 0ul;
              entries_written_list = (fun _ -> []);
              num_entries_written = 0ul;
              entries_scratch = advance_slice b 4ul } in
    assert (writer_valid w);
    Some w

let join_slices (b1 b2:bslice) : Pure (option bslice)
    (requires (buffers_adjacent b1.p b2.p))
    (ensures (fun r ->
      match r with
      | Some b -> is_concat_of b.p b1.p b2.p
      | None -> U32.v b1.len + U32.v b2.len >= pow2 32)) =
      if u32_add_overflows b1.len b2.len then None
      else let b' = BSlice (U32.add b1.len b2.len) (B.join b1.p b2.p) in
           Some b'

// TODO: implement this API

val writer_append (w:writer) (e:entry_st) : ST (option writer)
       (requires (fun h0 -> writer_inv h0 w /\
                         entry_live h0 e /\
                         disjoint_in h0 (entry_st_bufs e) w.entries_scratch ))
       (ensures (fun h0 w' h1 ->
                Some? w' ==>
                begin
                  let w' = Some?.v w' in
                  writer_inv h1 w' /\
                  entry_live h1 e /\
                  (let ee = as_entry h1 e in
                  w'.entries_written_list () == w.entries_written_list () `List.append` [ee])
                end))
let writer_append w e =
    let r = ser_entry e w.entries_scratch in
    match r with
    | Some off ->
      let (entries_done, entries_scratch') = bslice_split_at w.entries_scratch off in
      begin
        match join_slices w.entries_written_buf entries_done with
        | Some entries_written ->
            let w' = { length_field = w.length_field;
                       entries_written_buf = entries_written;
                       entries_scratch = entries_scratch';
                       entries_written_list = (fun _ -> w.entries_written_list ());
                       num_entries_written = U32.add w.num_entries_written 1ul } in
            admit();
            Some w'
        | None -> None
      end
    | None -> None

val join_is_concat (#t:Type) (b1 b2:B.buffer t) :
    Lemma (requires (same_ref b1 b2 /\
                     B.idx b1 + B.length b1 == B.idx b2))
          (ensures (same_ref b1 b2 /\
                    B.idx b1 + B.length b1 == B.idx b2 /\
                    is_concat_of (B.join b1 b2) b1 b2))
let join_is_concat #t b1 b2 = ()

let writer_store_buf (w:writer{writer_valid w}) : Pure bslice
  (requires True)
  (ensures (fun b -> is_concat_of b.p w.length_field w.entries_written_buf.p)) =
  let b1 = w.length_field in
  let b2 = w.entries_written_buf.p in
  join_is_concat b1 b2;
  BSlice (U32.add 4ul w.entries_written_buf.len) (B.join b1 b2)

// XXX: don't have a proof that ser_u32 will not fail if given a buffer of
// length 4 (and somehow F* doesn't prove this by unfolding the definition
// enough)
val writer_finish (w:writer) : ST (option bslice)
    (requires (fun h0 -> writer_inv h0 w))
    (ensures (fun h0 mb h1 ->
                Some? mb ==>
                begin
                let b = Some?.v mb in
                live h1 b /\
                (let bs = as_seq h1 b in
                 let entries = w.entries_written_list () in
                 List.length entries == U32.v w.num_entries_written /\
                 bs == encode_store (Store w.num_entries_written entries))
                end))
let writer_finish w =
    let length_buf = BSlice 4ul w.length_field in
    let r = ser_u32 w.num_entries_written length_buf in
    match r with
    | Some off ->
        let b = writer_store_buf w in
        begin
          let h1 = get() in
          assert (live h1 b);
          let bs = as_seq h1 b in
          let entries = w.entries_written_list () in
          let enc_entries = as_seq h1 w.entries_written_buf in
          assert (List.length entries == U32.v w.num_entries_written);
          // this is the only required part of this proof (everything else falls
          // out relatively easily)
          is_concat_append b.p w.length_field w.entries_written_buf.p h1;
          assert (bs == B.as_seq h1 w.length_field `append` enc_entries);
          ()
        end;
      Some b
    | None -> None
