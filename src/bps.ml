open Bigarray

type buffer = (int, int8_unsigned_elt, c_layout) Array1.t

type reader = {
  data : buffer;
  mutable cursor : int;
  limit : int;
}

let length = Array1.dim

let get data index = Array1.unsafe_get data index

let set data index value = Array1.unsafe_set data index value

let fail message = raise (Failure message)

let crc32_table =
  Array.init 256 (fun value ->
      let crc = ref (Int32.of_int value) in
      for _ = 1 to 8 do
        crc :=
          if Int32.logand !crc 1l <> 0l then
            Int32.logxor (Int32.shift_right_logical !crc 1) 0xedb88320l
          else Int32.shift_right_logical !crc 1
      done;
      !crc)

let crc32 data count =
  if count < 0 || count > length data then fail "Invalid CRC32 range.";
  let crc = ref Int32.minus_one in
  for index = 0 to count - 1 do
    let table_index =
      Int32.to_int
        (Int32.logand
           (Int32.logxor !crc (Int32.of_int (get data index)))
           0xffl)
    in
    crc :=
      Int32.logxor (Int32.shift_right_logical !crc 8)
        crc32_table.(table_index)
  done;
  Int32.logxor !crc Int32.minus_one

let read_u32_le data offset =
  if offset < 0 || offset + 4 > length data then fail "Invalid BPS footer.";
  Int32.logor (Int32.of_int (get data offset))
    (Int32.logor
       (Int32.shift_left (Int32.of_int (get data (offset + 1))) 8)
       (Int32.logor
          (Int32.shift_left (Int32.of_int (get data (offset + 2))) 16)
          (Int32.shift_left (Int32.of_int (get data (offset + 3))) 24)))

let read_number reader =
  let rec loop value shift =
    if reader.cursor >= reader.limit then fail "Truncated BPS patch.";
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
  let footer_offset = length patch - 12 in
  if footer_offset < 4 then fail "Invalid BPS footer.";
  let expected_source_crc = read_u32_le patch footer_offset in
  let expected_target_crc = read_u32_le patch (footer_offset + 4) in
  let expected_patch_crc = read_u32_le patch (footer_offset + 8) in
  if crc32 patch (length patch - 4) <> expected_patch_crc then
    fail "BPS patch checksum does not match.";
  if crc32 source (length source) <> expected_source_crc then
    fail "BPS source checksum does not match.";
  let reader = { data = patch; cursor = 4; limit = footer_offset } in
  let source_size = read_number reader in
  let output_size = read_number reader in
  let metadata_size = read_number reader in
  if source_size <> length source then fail "ROM size does not match patch.";
  reader.cursor <- reader.cursor + metadata_size;
  if reader.cursor > footer_offset then fail "Invalid BPS metadata.";
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
        if reader.cursor + count > footer_offset then
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
  if reader.cursor <> footer_offset then
    fail "BPS instruction stream contains trailing data.";
  if crc32 output (length output) <> expected_target_crc then
    fail "BPS target checksum does not match.";
  output

