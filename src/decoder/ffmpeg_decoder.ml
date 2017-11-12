(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2017 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

(** Decode and read metadata using ffmpeg. *)

open Dtools

let log = Log.make ["decoder";"ffmpeg"]

(** Configuration keys for ffmpeg. *)
let mime_types =
  Conf.list ~p:(Decoder.conf_mime_types#plug "ffmpeg")
    "Mime-types used for decoding with ffmpeg"
    ~d:[]

let file_extensions =
  Conf.list ~p:(Decoder.conf_file_extensions#plug "ffmpeg")
    "File extensions used for decoding with ffmpeg"
    ~d:["mp3"] (* Test *)

module ConverterInput = FFmpeg.Swresample.Make(FFmpeg.Swresample.Frame)
module Converter = ConverterInput(FFmpeg.Swresample.PlanarFloatArray)

module G = Generator.From_audio_video
module Buffered = Decoder.Buffered(G)

let create_decoder fname =
  let container =
    FFmpeg.Av.open_input fname
  in
  (* Only audio for now *)
  let (index, stream, codec) =
    FFmpeg.Av.find_best_audio_stream container
  in
  let sample_freq =
    FFmpeg.Avcodec.Audio.get_sample_rate codec
  in
  let in_sample_format =
    FFmpeg.Avcodec.Audio.get_sample_format codec
  in
  let channel_layout =
    FFmpeg.Avcodec.Audio.get_channel_layout codec
  in
  let target_channel_layout =
    FFmpeg.Avutil.Channel_layout.CL_stereo
  in
  let target_sample_rate =
    Lazy.force Frame.audio_rate
  in
  let converter =
    Converter.create channel_layout ~in_sample_format sample_freq
                     target_channel_layout target_sample_rate
  in 
  let convert frame =
    let data = 
      Converter.convert converter frame
    in
    let normalize pcm =
      pcm /. 10.
    in
    Array.map (Array.map normalize) data
  in
  let seek ticks =
    let position = Frame.seconds_of_master ticks in
    let position = Int64.of_float
      (position *. 1000.)
   in
    let time_format = FFmpeg.Avutil.Time_format.Millisecond in
    try
      FFmpeg.Av.seek stream time_format position [||];
      ticks
    with Failure _ -> 0
  in
  let decode gen =
    let content =
      match FFmpeg.Av.read stream with
        | FFmpeg.Av.Frame frame -> convert frame
        | FFmpeg.Av.End_of_stream -> [|[||];[||]|]
    in
    G.set_mode gen `Audio ;
    G.put_audio gen content 0 (Array.length content.(0))
  in
  { Decoder.
     seek = seek;
     decode = decode }

let create_file_decoder filename kind =
  let generator = G.create `Audio in
  let remaining frame offset = 
    -1
  in
  let decoder =
    create_decoder filename
  in
  Buffered.make_file_decoder ~filename ~kind ~remaining decoder generator 

(* Get the number of channels of audio in a file.
 * This is done by decoding a first chunk of data, thus checking
 * that libmad can actually open the file -- which doesn't mean much. *)
let get_type filename =
  let container =
    FFmpeg.Av.open_input filename
  in
  let (index, stream, codec) =
    FFmpeg.Av.find_best_audio_stream container
  in
  let channels =
    FFmpeg.Avcodec.Audio.get_nb_channels codec
  in
  let rate =
    FFmpeg.Avcodec.Audio.get_sample_rate codec
  in
  log#f 4 "ffmpeg recognizes %S as: (%dHz,%d channels)."
    filename rate channels ;
  {Frame.
     audio = channels ;
     video = 0 ;
     midi  = 0 }

let () =
  Decoder.file_decoders#register
  "FFMPEG"
  ~sdoc:"Use libffmpeg to decode any file \
         if its MIME type or file extension is appropriate."
  (fun ~metadata:_ filename kind ->
     if not (Decoder.test_file ~mimes:mime_types#get 
                               ~extensions:file_extensions#get
                               ~log filename) then
       None
     else
       if kind.Frame.audio = Frame.Variable ||
          kind.Frame.audio = Frame.Succ Frame.Variable ||
          (* libmad always respects the first two kinds *)
          if Frame.type_has_kind (get_type filename) kind then true else begin
            log#f 3
              "File %S has an incompatible number of channels."
              filename ;
            false
          end
       then
         Some (fun () -> create_file_decoder filename kind)
       else
         None)

let log = Dtools.Log.make ["metadata";"ffmpeg"]

let get_tags file =
  let container =
    FFmpeg.Av.open_input file
  in
  FFmpeg.Av.get_input_metadata container

let () = Request.mresolvers#register "FFMPEG" get_tags

let check filename =
  match Configure.file_mime with
    | Some f -> List.mem (f filename) mime_types#get
    | None -> (try ignore (get_type filename) ; true with _ -> false)

let duration file =
  let container =
    FFmpeg.Av.open_input file
  in
  let duration =
    FFmpeg.Av.get_input_duration container FFmpeg.Avutil.Time_format.Millisecond
  in
  (Int64.to_float duration) /. 1000.

let () =
  Request.dresolvers#register "FFMPEG" duration