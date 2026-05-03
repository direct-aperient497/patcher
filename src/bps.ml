open Bigarray

type buffer = (int, int8_unsigned_elt, c_layout) Array1.t

type reader = {
  data : buffer;
  mutable cursor : int;
}

let length = Array1.dim

let get data index = Array1.unsafe_get data index

let set data index value = Array1.unsafe_set data index value

let fail message = raise (Failure message)

let read_number reader =
  let rec loop value shift =
    if reader.cursor >= length reader.data then fail "Truncated BPS patch.";
    let byte = get reader.data reader.cursor in
    reader.cursor <- reader.cursor + 1;
    let value = value + ((byte land 0x7f) * shift) in
    if byte land 0x80 <> 0 then value
    else
      let shift = shift * 128 in
      loop (value + shift) shift
  in
  loop 0 1

let read_signed reader =
  let value = read_number reader in
  if value land 1 <> 0 then -(value lsr 1) else value lsr 1

let blit source source_offset target target_offset count =
  Array1.blit
    (Array1.sub source source_offset count)
    (Array1.sub target target_offset count)

let has_header patch =
  length patch >= 4
  && get patch 0 = Char.code 'B'
  && get patch 1 = Char.code 'P'
  && get patch 2 = Char.code 'S'
  && get patch 3 = Char.code '1'

let apply source patch =
  if not (has_header patch) then fail "Invalid BPS patch file.";
  let reader = { data = patch; cursor = 4 } in
  let source_size = read_number reader in
  let output_size = read_number reader in
  let metadata_size = read_number reader in
  if source_size <> length source then fail "ROM size does not match patch.";
  reader.cursor <- reader.cursor + metadata_size;
  if reader.cursor > length patch - 12 then fail "Invalid BPS metadata.";
  let output = Array1.create int8_unsigned c_layout output_size in
  let output_offset = ref 0 in
  let source_relative_offset = ref 0 in
  let target_relative_offset = ref 0 in
  while !output_offset < output_size do
    let action = read_number reader in
    let mode = action land 3 in
    let count = (action lsr 2) + 1 in
    if !output_offset + count > output_size then
      fail "BPS action is out of range.";
    match mode with
    | 0 ->
        if !output_offset + count > length source then
          fail "BPS source read is out of range.";
        blit source !output_offset output !output_offset count;
        output_offset := !output_offset + count
    | 1 ->
        if reader.cursor + count > length patch - 12 then
          fail "BPS target read is truncated.";
        blit patch reader.cursor output !output_offset count;
        reader.cursor <- reader.cursor + count;
        output_offset := !output_offset + count
    | 2 ->
        source_relative_offset :=
          !source_relative_offset + read_signed reader;
        if
          !source_relative_offset < 0
          || !source_relative_offset + count > length source
        then fail "BPS source copy is out of range.";
        blit source !source_relative_offset output !output_offset count;
        source_relative_offset := !source_relative_offset + count;
        output_offset := !output_offset + count
    | _ ->
        target_relative_offset :=
          !target_relative_offset + read_signed reader;
        if
          !target_relative_offset < 0
          || !target_relative_offset >= !output_offset
        then fail "BPS target copy is out of range.";
        for _ = 1 to count do
          set output !output_offset (get output !target_relative_offset);
          incr output_offset;
          incr target_relative_offset
        done
  done;
  output

