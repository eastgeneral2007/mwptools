/*
 * Copyright (C) 2014 Jonathan Hudson <jh+mwptools@daria.co.uk>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 3
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
 */

public class SwitchEdit : Object
{
    const int NBITS=12;
    const int NMODES=20;
    private struct PERM_BOX
    {
        string name;
        uint8  permid;
    }

    private Gtk.Builder builder;
    private Gtk.Window window;
    private Gtk.Grid grid1;
    private Gtk.Button conbutton;
    private Gtk.Label verslab;
    private MWSerial s;
    private bool is_connected;
    private bool have_box;
    private bool have_names;
    private bool have_vers;
    private Gtk.ProgressBar lvbar[8];
    private Gtk.Label[] boxlabel;
    private Gtk.CheckButton[] checks;
    private uint nboxen;
    private uint32 xflag = -1;
    private Gdk.RGBA[] colors;
    private string lastfile;
    private uint32 capability;
    private uint8 []rowids;
    private uint8 []permids;
    private bool applied = false;
    private uint nranges = NMODES;
    private MWChooser.MWVAR mwvar=MWChooser.MWVAR.AUTO;
    private uint cmdtid;
    private uint8 api_cnt = 0;

    private static string serdev;
    private static string mwoptstr;
    private Timer timer;
    private uint8 icount = 0;
    private CF_MODE_RANGES []mrs;
    private uint8 mrs_idx;
    private int intvl;
    private PERM_BOX [] pbox;

    const OptionEntry[] options = {
        { "serial-device", 's', 0, OptionArg.STRING, out serdev, "Serial device", null},
        { "flight-controller", 'f', 0, OptionArg.STRING, out mwoptstr, "mw|mwnav|cf", null},
        {null}
    };

    private const PERM_BOX [] def_pbox = {
        {"ARM", 0},
        {"ANGLE", 1},
        {"HORIZON", 2},
        {"BARO", 3},
        {"VARIO", 4 },
        {"MAG", 5 },
        {"HEADFREE", 6 },
        {"HEADADJ", 7 },
        {"CAMSTAB", 8 },
        {"CAMTRIG", 9 },
        {"GPS HOME", 10 },
        {"GPS HOLD", 11 },
        {"PASSTHRU", 12 },
        {"BEEPER", 13 },
        {"LEDMAX", 14 },
        {"LEDLOW", 15 },
        {"LLIGHTS", 16 },
        {"CALIB", 17 },
        {"GOVERNOR", 18 },
        {"OSD SW", 19 },
        {"TELEMETRY", 20 },
        {"AUTOTUNE", 21 },
        {"SONAR", 22 },
        {"SERVO1", 23 },
        {"SERVO2", 24 },
        { "SERVO3", 25 },
        { "BLACKBOX", 26 },
        { "FAILSAFE", 27 },
        {"AIR MODE", 28 }
    };

    private const PERM_BOX [] inav_pbox = {
        { "ARM", 0 },
        { "ANGLE", 1 },
        { "HORIZON", 2 },
        { "NAV ALTHOLD", 3 },   // old BARO
        { "MAG", 5 },
        { "HEADFREE", 6 },
        { "HEADADJ", 7 },
        { "CAMSTAB", 8 },
        { "CAMTRIG", 9 },
        { "NAV RTH", 10 },         // old GPS HOME
        { "NAV POSHOLD", 11 },     // old GPS HOLD
        { "PASSTHRU", 12 },
        { "BEEPER", 13 },
        { "LEDMAX", 14 },
        { "LEDLOW", 15 },
        { "LLIGHTS", 16 },
        { "CALIB", 17 },
        { "GOVERNOR", 18 },
        { "OSD SW", 19 },
        { "TELEMETRY", 20 },
        { "GTUNE", 21 },
        { "SERVO1", 23 },
        { "SERVO2", 24 },
        { "SERVO3", 25 },
        { "BLACKBOX", 26 },
        { "FAILSAFE", 27 },
        { "NAV WP", 28 },
        { "AIR MODE", 29 }
    };

    private void remove_tid(ref uint tid)
    {
        if(tid > 0)
            Source.remove(tid);
        tid = 0;
    }

    private void add_cmd(MSP.Cmds cmd, void* buf, size_t len, ref bool flag, uint32 wait=1000)
    {
        var _flag = flag;
        cmdtid = Timeout.add(wait, () => {
                if (_flag == false)
                {
                    if(cmd == MSP.Cmds.API_VERSION)
                    {
                        api_cnt++;
                        if(api_cnt == 1)
                        {
                            api_cnt = 255;
                            cmd = MSP.Cmds.IDENT;
                        }
                    }
                    var t = timer.elapsed();
                    stderr.printf("%6.1f repcmd %d\n", t, cmd);
                    s.send_command(cmd,buf,len);
                    return true;
                }
                else
                {
                    return false;
                }
            });
        s.send_command(cmd,buf,len);
    }

    private void get_settings(out string[] devs, out uint baudrate)
    {
        devs={};
        baudrate=0;
        SettingsSchema schema = null;
        Settings settings = null;
        var sname = "org.mwptools.planner";
        var uc = Environment.get_user_data_dir();
        uc += "/glib-2.0/schemas/";
        try
        {
            SettingsSchemaSource sss = new SettingsSchemaSource.from_directory (uc, null, false);
            schema = sss.lookup (sname, false);
        } catch {}

        if (schema != null)
            settings = new Settings.full (schema, null, null);
        else
            settings =  new Settings (sname);

        if (settings != null)
        {
            devs = settings.get_strv ("device-names");
            baudrate = settings.get_uint("baudrate");
            string smwvar = settings.get_string("fctype");
            if(smwvar != null)
                mwvar = MWChooser.fc_from_name(smwvar);
        }
    }

    private void apply_state()
    {
        uint16[] sv = new uint16[nboxen];
        for(var ib = 0; ib < nboxen; ib++)
        {
            sv[ib] = 0;
            for(var jb = 0; jb < NBITS; jb++)
            {
                var kb = jb + ib * NBITS;
                if(checks[kb].active)
                    sv[ib] |= (1 << jb);
            }
        }

        if(mwvar != MWChooser.MWVAR.CF) // MW
        {
            s.send_command(MSP.Cmds.SET_BOX, sv, nboxen*2);
        }
        else
        {
            uint8 aid=0;
            mrs = new CF_MODE_RANGES[128];
            for(var ib = 0; ib < nboxen; ib++)
            {
                for(var j = 0; j < 4; j++)
                {
                    var auxbits = ((sv[ib] >> j*3) & 7);
                    mrs[aid].perm_id = permids[ib];
                    mrs[aid].auxchanid = j;
                    switch (auxbits)
                    {
                        case 0:
                            break;

                        case 1:
                            mrs[aid].startstep = 0;
                            mrs[aid].endstep = 16;
                            aid++;
                            break;
                        case 2:
                            mrs[aid].startstep = 16;
                            mrs[aid].endstep = 32;
                            aid++;
                            break;
                        case 3:
                            mrs[aid].startstep = 0;
                            mrs[aid].endstep = 32;
                            aid++;
                            break;
                        case 4:
                            mrs[aid].startstep = 32;
                            mrs[aid].endstep = 48;
                            aid++;
                            break;
                        case 5:
                            mrs[aid].startstep = 0;
                            mrs[aid].endstep = 16;
                            aid++;
                            mrs[aid].perm_id = permids[ib];
                            mrs[aid].auxchanid = j;
                            mrs[aid].startstep = 32;
                            mrs[aid].endstep = 48;
                            aid++;
                            break;
                        case 6:
                            mrs[aid].startstep = 16;
                            mrs[aid].endstep = 48;
                            aid++;
                            break;
                        case 7:
                            mrs[aid].startstep = 0;
                            mrs[aid].endstep = 48;
                            aid++;
                            break;
                    }
                }
            }
            for(;aid < nranges;aid++)
                mrs[aid] = {0,0,0,0};

            mrs_idx = 0;
            send_mrs();
            applied = true;
        }
    }


    private void send_mrs()
    {
        uint8 buf[5];
        buf[0] = mrs_idx;
        buf[1] = mrs[mrs_idx].perm_id;
        buf[2] = mrs[mrs_idx].auxchanid;
        buf[3] = mrs[mrs_idx].startstep;
        buf[4] = mrs[mrs_idx].endstep;
//        stderr.printf("send mr %d\n", mrs_idx);
        mrs_idx++;
        if(mrs_idx < nranges)
            s.send_command(MSP.Cmds.SET_MODE_RANGE, buf, 5);
    }

    private void start_status_timer()
    {
        var baud = s.baudrate;
        if(baud == 0 || baud > 50000)
            intvl = 100;
        else if (baud > 32000)
            intvl = 200;
        else
            intvl = 400;

        Timeout.add(intvl, () => {
                s.send_command(MSP.Cmds.STATUS,null,0);
//                s.send_command(MSP.Cmds.RC,null,0);
                return false;
            });

    }

    SwitchEdit()
    {
        mwvar = MWChooser.fc_from_arg0();

        string[] devs;
        uint baudrate;
        get_settings(out devs, out baudrate);

        if(mwoptstr != null)
        {
            mwvar = MWChooser.fc_from_name(mwoptstr);
        }

        is_connected = false;
        have_names = false;
        have_box = false;
        boxlabel = {};
        checks= {};
        rowids = {};
        permids = {};

        colors = new Gdk.RGBA[2];
        colors[1].parse("orange");
        colors[0].parse("white");

        builder = new Gtk.Builder ();
        var fn = MWPUtils.find_conf_file("switchedit.ui");
        if (fn == null)
        {
            MWPLog.message ("No UI definition file\n");
            Gtk.main_quit();
        }
        else
        {
            try
            {
                builder.add_from_file (fn);
            } catch (Error e) {
                MWPLog.message ("Builder: %s\n", e.message);
                Gtk.main_quit();
            }
        }
        fn = MWPUtils.find_conf_file("mwchooser.ui");
        if (fn == null)
        {
            MWPLog.message ("No UI chooser definition file\n");
            Posix.exit(255);
        }
        else
        {
            try
            {
                builder.add_from_file (fn);
            } catch (Error e) {
                MWPLog.message ("Builder: %s\n", e.message);
                Posix.exit(255);
            }
        }

        builder.connect_signals (null);
        window = builder.get_object ("window2") as Gtk.Window;
        grid1 = builder.get_object ("grid1") as Gtk.Grid;
        for(var i = 0; i < 8;)
        {
            var j = i+1;
            lvbar[i] =  builder.get_object ("progressbar%d".printf(j)) as Gtk.ProgressBar;
            i = j;
        }

        window.destroy.connect (Gtk.main_quit);

        var mwc = new MWChooser(builder);
        if(mwvar == MWChooser.MWVAR.UNDEF)
        {
            mwvar = mwc.get_version(MWChooser.MWVAR.MWOLD);
        }

        if(mwvar == MWChooser.MWVAR.UNDEF)
        {
            Posix.exit(255);
        }

        s = new MWSerial();

        timer = new Timer();
        pbox = def_pbox;
        s.serial_event.connect((sd,cmd,raw,len,xflags,errs) => {
                remove_tid(ref cmdtid);
                if(errs == true)
                {
                    if(cmd == MSP.Cmds.API_VERSION)
                    {
                        have_vers = false;
                        add_cmd(MSP.Cmds.IDENT,null,0, ref have_vers,2000);
                    }
                    MWPLog.message("Error on cmd %d\n", cmd);
                    return;
                }
                switch(cmd)
                {
                    case MSP.Cmds.API_VERSION:
                    stderr.printf("Not supported -- use the configurator\n");
                    Posix.exit(255);
                    mwvar = MWChooser.MWVAR.CF;
                    have_vers = false;
                    add_cmd(MSP.Cmds.FC_VARIANT,null,0, ref have_vers,2000);
                    break;


                    case MSP.Cmds.FC_VARIANT:
                    raw[4] = 0;
                    string cfvar = (string)raw[0:4];
                    if (cfvar  == "INAV")
                    {
                        pbox = inav_pbox;
                    }
                    have_vers = false;
                    add_cmd(MSP.Cmds.IDENT,null,0, ref have_vers,2000);
                    break;

                    case MSP.Cmds.IDENT:
                    have_vers = true;
                    if(icount == 0)
                    {
                        deserialise_u32(raw+3, out capability);
                        var _mrtype = MSP.get_mrtype(raw[1]);
                        if(mwvar == MWChooser.MWVAR.AUTO)
                        {
                            if((capability & MSPCaps.CAP_PLATFORM_32BIT) != 0)
                            {
                                mwvar = MWChooser.MWVAR.CF;
                            }
                            else
                            {
                                mwvar = ((capability & 0x10) == 0x10) ? MWChooser.MWVAR.MWNEW : MWChooser.MWVAR.MWOLD;
                            }
                        }
                        var vers="%s v%03d %s".printf(MWChooser.mwnames[mwvar], raw[0], _mrtype);
                        verslab.set_label(vers);

                        add_cmd(MSP.Cmds.BOXNAMES,null,0, ref have_names);
                    }
                    icount++;
                    break;

                    case MSP.Cmds.BOXNAMES:
                    have_names = true;
                    string b = (string)raw;
                    string []bsx = b.split(";");
                    nboxen = bsx.length-1;
                    add_boxlabels(bsx);
                    MSP.Cmds bcmd = (mwvar != MWChooser.MWVAR.CF) ? MSP.Cmds.BOX : MSP.Cmds.MODE_RANGES;
                    if(have_box == false)
                        add_cmd(bcmd,null,0, ref have_box);
                    break;

                    case  MSP.Cmds.MODE_RANGES:
                    have_box = true;
                    xflag = 0;
                    add_cf_modes(raw, len);
                    start_status_timer();
                    break;


                    case MSP.Cmds.BOX:
                    if(have_box == false)
                    {
                        have_box = true;
                        add_switch_states((uint16[])raw);
                    }
                    grid1.show_all();
                    xflag = 0;
                    start_status_timer();
                    break;

                    case MSP.Cmds.RC:
                    uint16[] rc = (uint16[])raw;
                    for(var i = 0; i < 8; i++)
                    {
                        double d = (double)rc[i];
                        d = (d-1000)/1000.0;
                        lvbar[i].set_text(rc[i].to_string());
                        lvbar[i].set_fraction(d);
                    }
                    Timeout.add(intvl, () => {
                            s.send_command(MSP.Cmds.STATUS,null,0);
                            return false;
                        });
                    break;

                    case MSP.Cmds.STATUS:
                    uint32 sflag;
                    deserialise_u32(raw+6, out sflag);
                    if(xflag != sflag)
                    {
                        for(var j = 0; j < nboxen; j++)
                        {
                            uint32 mask = (1 << j);
                            if((sflag & mask) != (xflag & mask))
                            {
                                int icol;
                                if ((sflag & mask) == mask)
                                    icol = 1;
                                else
                                    icol = 0;

                                boxlabel[j].override_background_color(Gtk.StateFlags.NORMAL, colors[icol]);
                            }
                        }
                        xflag = sflag;
                    }
                    Timeout.add(intvl, () => {
                            s.send_command(MSP.Cmds.RC,null,0);
                            return false;
                        });
                    break;
                    case MSP.Cmds.SET_MODE_RANGE:
                    send_mrs();
                    break;
                    default:
                    break;
                }
            });

        try {
            string icon=null;
            icon = MWPUtils.find_conf_file("switchedit.svg");
            window.set_icon_from_file(icon);
        } catch {};

        var dentry = builder.get_object ("comboboxtext1") as Gtk.ComboBoxText;
        conbutton = builder.get_object ("button4") as Gtk.Button;

        if(serdev != null)
        {
            dentry.prepend_text(serdev);
            dentry.active = 0;
        }

	foreach(string a in devs)
        {
            dentry.append_text(a);
        }

        var te = dentry.get_child() as Gtk.Entry;
        te.can_focus = true;
        dentry.active = 0;

        verslab = builder.get_object ("verslab") as Gtk.Label;
        verslab.set_label("");

        var saveasbutton = builder.get_object ("button5") as Gtk.Button;
        saveasbutton.clicked.connect(() => {
                save_file();
            });
        saveasbutton.set_sensitive(false);

        var openbutton = builder.get_object ("button3") as Gtk.Button;
        openbutton.clicked.connect(() => {
                load_file();
                saveasbutton.set_sensitive(true);
            });

        var applybutton = builder.get_object ("button1") as Gtk.Button;
        applybutton.clicked.connect(() => {
                if(is_connected == true && have_names == true)
                {
                    if(applied == false)
                        apply_state();
                    s.send_command(MSP.Cmds.EEPROM_WRITE,null, 0);
                }
            });
        applybutton.set_sensitive(false);

        var closebutton = builder.get_object ("button2") as Gtk.Button;
        closebutton.clicked.connect(() => {
                Gtk.main_quit();
            });

        conbutton.clicked.connect(() => {
                string estr;
                if (is_connected == false)
                {
                    serdev = dentry.get_active_text();
                    if(s.open(serdev,baudrate, out estr) == true)
                    {
                        is_connected = true;
                        conbutton.set_label("Disconnect");
                        applybutton.set_sensitive(true);
                        saveasbutton.set_sensitive(true);
                        api_cnt = 0;
                        icount  = 0;
                        if(mwvar == MWChooser.MWVAR.CF ||
                           mwvar == MWChooser.MWVAR.AUTO) // CF
                            add_cmd(MSP.Cmds.API_VERSION,null,0, ref have_vers);
                        else
                            add_cmd(MSP.Cmds.IDENT,null,0, ref have_vers);
                    }
                    else
                    {
                        MWPLog.message("open failed %s %s\n", serdev, estr);
                    }
                }
                else
                {
                    remove_tid(ref cmdtid);
                    xflag = 0;
                    s.close();
                    conbutton.set_label("Connect");
                    applybutton.set_sensitive(false);
                    saveasbutton.set_sensitive(false);
                    verslab.set_label("");
                    cleanupui();
                }
                grid1.hide();
            });

        window.show_all();
        grid1.hide();
    }

    private void cleanupui()
    {

        have_vers = false;
        is_connected = false;
        have_names = false;
        have_box = false;
        foreach (var l in lvbar)
        {
            l.set_text("0");
            l.set_fraction(0.0);
        }
        foreach (var b in boxlabel)
        {
            b.destroy();
        }
        boxlabel={};
        nboxen = 0;
        foreach(var c in checks)
        {
            c.destroy();
        }
        checks = {};
        grid1.hide();
    }

    private void add_boxlabels(string[]bsx)
    {
        boxlabel={};
        rowids = new uint8[NMODES];
        permids = new uint8[nboxen];

        for(var i = 0; i < nboxen; i++)
        {
            var l = new Gtk.Label("");
            l.set_width_chars(10);
            l.justify = Gtk.Justification.LEFT;
            l.halign = Gtk.Align.START;
//            MWPLog.message("Box %d %s\n", i, bsx[i]);
            l.set_label(bsx[i]);
            boxlabel += l;
            l.override_background_color(Gtk.StateFlags.NORMAL, colors[0]);
            grid1.attach(l,0,i+2,1,1);
            for(var j = 0; j < pbox.length; j++)
            {
                if (bsx[i] == pbox[j].name)
                {
                    rowids[pbox[j].permid] = i;
                    permids[i] = pbox[j].permid;
                }
            }
        }
        build_check_boxen();
    }

    private void add_cf_modes(uint8[]raw, uint len)
    {
        nranges = len / 4;
        uint16[] bv = new uint16[nboxen];

        foreach(var bvi in bv)
            bvi=0;

        var idx = 0;
        var ridx = 0;

        for(var i = 0; i < nranges; i++)
        {
            CF_MODE_RANGES mr={};
            mr.perm_id = raw[idx++];
            mr.auxchanid = raw[idx++];
            mr.startstep = raw[idx++];
            mr.endstep = raw[idx++];
            if(mr.startstep !=  mr.endstep)
            {
                ridx = rowids[mr.perm_id];
                var bix = step_to_idx(mr.startstep, mr.endstep);
                bv[ridx] |= bix*(1 << mr.auxchanid*3);

/*
                MWPLog.message("auxid = %d, rowid = %d, name = %s ",
                              mr.auxchanid, ridx, pbox[mr.perm_id].name);
                MWPLog.message("min=%d, max=%d idx=%u val %x\n",
                              mr.startstep, mr.endstep, bix, bv[idx]);
*/
            }
/*
            MWPLog.message("permid = %d, auxid  = %d, range %d %d, row %d = %s\n",
                          mr.perm_id, mr.auxchanid, mr.startstep, mr.endstep,
                          ridx, pbox[mr.perm_id].name);
*/
        }
        add_switch_states(bv);
    }

    private uint8 step_to_idx(uint8 start, uint8 end)
    {
        uint8 mask;
        var rng = (end - start)/16;
        var st = start/16;
        mask = ((1 << rng)-1)*(1 << st);
        return mask;
    }

    private void build_check_boxen()
    {
        checks={};
        for(var i = 0; i < nboxen; i++)
        {
            var k = 0;
            for(var j = 0; j < NBITS; j++)
            {
                Gtk.CheckButton c = new Gtk.CheckButton();
                checks += c;

                if((j % 3)  == 0 && j != 0)
                {
                    k += 1;
                    var s = new Gtk.Separator(Gtk.Orientation.VERTICAL);
                    grid1.attach(s,k,i+2,1,1);
                    k += 1;
                }
                else
                    k += 1;

                grid1.attach(c,k,i+2,1,1);
                c.show();
            }
        }
        grid1.show_all();
    }

    private void add_switch_states(uint16[] bv)
    {
        var l = 0;
        for(var i = 0; i < nboxen; i++)
        {
            for(var j = 0; j < NBITS; j++)
            {
                uint16 mask = (1 << j);
                var c = checks[l++];
                c.active = ((bv[i] & mask) == mask);
                c.toggled.connect(() => {
                        apply_state();
                    });
            }
        }
      }

    private void save_file()
    {
        var chooser = new Gtk.FileChooserDialog (
            "Save switches", window,
            Gtk.FileChooserAction.SAVE,
            "_Cancel", Gtk.ResponseType.CANCEL,
            "_Save",  Gtk.ResponseType.ACCEPT);

        if(lastfile == null)
        {
            chooser.set_current_name("untitled-switches.json");
        }
        else
        {
            chooser.set_filename(lastfile);
        }

        if (chooser.run () == Gtk.ResponseType.ACCEPT)
        {
            lastfile = chooser.get_filename();
            save_data();
        }
        chooser.close ();
    }

    private void load_file()
    {
        var chooser = new Gtk.FileChooserDialog (
            "Load switch file", window, Gtk.FileChooserAction.OPEN,
            "_Cancel",
            Gtk.ResponseType.CANCEL,
            "_Open",
            Gtk.ResponseType.ACCEPT);

        Gtk.FileFilter filter = new Gtk.FileFilter ();
        filter.set_filter_name ("JSON switch files");
        filter.add_pattern ("*.json");
        chooser.add_filter (filter);
        filter = new Gtk.FileFilter ();
        filter.set_filter_name ("All Files");
        filter.add_pattern ("*");
        chooser.add_filter (filter);

        string fn = null;
        if (chooser.run () == Gtk.ResponseType.ACCEPT) {
            fn= chooser.get_filename();
        }
        chooser.close ();

        if(fn != null)
        {
            lastfile = fn;
            if(nboxen != 0)
            {
                var x_have_vers = have_vers;
                var x_is_connected = is_connected;
                cleanupui();
                have_vers = x_have_vers;
                is_connected = x_is_connected;
            }

            try
            {
                var parser = new Json.Parser ();
                parser.load_from_file (lastfile );
                var root_object = parser.get_root ().get_object ();
                var arry = root_object.get_array_member ("switches");
                nboxen = arry.get_length ();
                string[] bsx = new string[nboxen];
                uint16[] bv = new uint16[nboxen];
                var r = 0;
                foreach (var node in arry.get_elements ())
                {
                    uint16 sval = 0;
                    var item = node.get_object ();
                    bsx[r]= item.get_string_member("name");
                    string str = item.get_string_member ("value");
                    int j = 0;
                    foreach (var b in str.data)
                    {
                        switch(b)
                        {
                            case 'X':
                                sval |= (1 << j);
                                j++;
                                break;
                            case '_':
                                j++;
                                break;
                        }
                    }
                    bv[r] = sval;
                    r++;
                }
                add_boxlabels(bsx);
                add_switch_states(bv);
                grid1.show_all();
                xflag = 0;
                have_names = true;
                have_box = true;
            } catch (Error e) {
                MWPLog.message ("Failed to parse file\n");
            }
        }
    }

    private void save_data()
    {
        Json.Generator gen;
        gen = new Json.Generator ();
        Json.Builder builder = new Json.Builder ();
        builder.begin_object ();

        builder.set_member_name ("multiwii");
        builder.add_string_value ("2.3");

        builder.set_member_name ("date");
        var dt = new DateTime.now_utc();
	builder.add_string_value (dt.to_string());

        builder.set_member_name ("switches");
        builder.begin_array ();
        var idx=0;
        for(var r = 0; r < nboxen; r++)
        {
             builder.begin_object ();
             builder.set_member_name ("id");
             builder.add_int_value (r);
             builder.set_member_name ("name");
             builder.add_string_value (boxlabel[r].get_label());
             builder.set_member_name ("value");
             uint8 bstr[16];
             int i = 0;
             for(var j =  0; j < NBITS; j++)
             {
                  if(j > 0 && (j%3)==0)
                  {
                      bstr[i++]=' ';
                  }

                  if(checks[idx].active)
                  {
                      bstr[i++]='X';
                  }
                  else
                  {
                      bstr[i++]='_';
                  }
                  idx++;
             }
             builder.add_string_value ((string)bstr);
             builder.end_object ();
         }
         builder.end_array();
         builder.end_object ();
         Json.Node root = builder.get_root ();
         gen.set_pretty(true);
         gen.set_root (root);
         var json = gen.to_data(null);
         try{
             FileUtils.set_contents(lastfile,json);
         }catch(Error e){
             MWPLog.message ("Error: %s\n", e.message);
         }
    }

    public void run()
    {
        Gtk.main();
    }

    public static int main (string[] args)
    {
        Gtk.init(ref args);
        try {
            var opt = new OptionContext("");
            opt.set_help_enabled(true);
            opt.add_main_entries(options, null);
            opt.parse(ref args);
        } catch (OptionError e) {
            stderr.printf("Error: %s\n", e.message);
            stderr.printf("Run '%s --help' to see a full list of available "+
                          "options\n", args[0]);
            return 1;
        }
        SwitchEdit app = new SwitchEdit();
        app.run ();
        return 0;
    }
}
