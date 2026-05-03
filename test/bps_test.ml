open Bigarray

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () ->
      let size = in_channel_length channel in
      let bytes = Bytes.create size in
      really_input channel bytes 0 size;
      let output = Array1.create int8_unsigned c_layout size in
      for index = 0 to size - 1 do
        Array1.unsafe_set output index (Char.code (Bytes.unsafe_get bytes index))
      done;
      output)

let write_file path data =
  let size = Array1.dim data in
  let bytes = Bytes.create size in
  for index = 0 to size - 1 do
    Bytes.unsafe_set bytes index (Char.chr (Array1.unsafe_get data index))
  done;
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_bytes channel bytes)

let () =
  if Array.length Sys.argv <> 4 then
    failwith "Usage: bps_test SOURCE PATCH OUTPUT";
  let source = read_file Sys.argv.(1) in
  let patch = read_file Sys.argv.(2) in
  write_file Sys.argv.(3) (Bps.apply source patch)

