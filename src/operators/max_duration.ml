(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2019 Savonet team

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
  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA

 *****************************************************************************)

(** This one is a bit tricky as we want to make sure
 *  that the underlying source is cleaned up when it's done
 *  pulling. Used in switch-based transitions to avoid infinite
 *  stack of sources. *)
class max_duration ~kind ~override_meta ~duration source =
object(self)
  inherit Source.operator ~name:"max_duration" kind [] as super

  val mutable remaining = duration
  val mutable s : Source.source = source

  method get_ready ?dynamic activation =
    super#get_ready ?dynamic activation ;
    s#get_ready ~dynamic:true [(self:>Source.source)]
  method leave ?dynamic src =
    super#leave ?dynamic src;
    s#leave ~dynamic:true (self:>Source.source)

  method stype = Source.Fallible
  method is_ready =
    remaining > 0 && s#is_ready
  method abort_track =
    s#abort_track
  method remaining =
    match remaining, s#remaining with
      | 0, _ -> 0
      | _, -1 -> -1
      | rem,rem' -> min rem rem'

  method private check_for_override ~offset buf =
    List.iter (fun (p,m) ->
      if p >= offset then
        Hashtbl.iter (fun lbl v ->
          if lbl = override_meta then
            try
              let v = float_of_string v in
              remaining <- Frame.master_of_seconds v;
              self#log#f 4 "Overriding remaining value: %.02f." v
            with _ ->
              self#log#f 3 "Invalid remaining override value: %s." v) m)
                (Frame.get_all_metadata buf)

  method private get_frame buf =
    let offset = Frame.position buf in
    s#get buf ;
    self#check_for_override ~offset buf ;
    remaining <- remaining - Frame.position buf + offset;
    if remaining <= 0 then
     begin
      s#leave ~dynamic:true (self:>Source.source);
      s <- ((new Blank.empty ~kind):>Source.source);
      s#get_ready ~dynamic:true [(self:>Source.source)]
     end
end

let () =
  let k = Lang.univ_t 1 in
  Lang.add_operator "max_duration"
    [ "override", Lang.string_t, Some (Lang.string "liq_remaining"),
      Some "Metadata field which, if present and containing a float, \
            overrides the remaining play time.";
      "", Lang.float_t, None, Some "Maximum duration";
      "", Lang.source_t k, None, None ]
    ~category:Lang.TrackProcessing
    ~descr:"Limit source duration"
    ~kind:(Lang.Unconstrained k)
    (fun p kind ->
      let override_meta =
        Lang.to_string (List.assoc "override" p)
      in
      let duration =
        Frame.master_of_seconds
          (Lang.to_float (Lang.assoc "" 1 p))
      in
      let s =
        Lang.to_source (Lang.assoc "" 2 p)
      in
      new max_duration ~kind ~override_meta ~duration s) 