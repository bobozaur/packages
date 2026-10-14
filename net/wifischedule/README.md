# wifischedule
Turns WiFi on and off according to a schedule on an openwrt router

## Components
* wifischedule: Shell script that creates cron jobs based on configuration provided in UCI and does all the other logic of enabling and disabling wifi with the use of `/sbin/wifi` and `/usr/bin/iwinfo`. Can be used standalone.
* luci-app-wifischedule: LUCI frontend for creating the UCI configuration and triggering the actions. Depends on wifischedule.


## Use cases
You can create user-defined events when to enable or disable WiFi. 
There are various use cases why you would like to do so:

1. Reduce power consumption and therefore reduce CO2 emissions.
2. Reduce emitted electromagnatic radiation.
3. Force busincess hours when WiFi is available.

Regarding 1: Please note, that you need to unload the wireless driver modules in order to get the most effect of saving power.
In my test scenario only disabling WiFi saves about ~0.4 Watt, unloading the modules removes another ~0.4 Watt.

Regarding 2: Think of a wireless accesspoint e.g. in your bedrom, kids room where you want to remove the ammount of radiation emitted.

Regarding 3: E.g. in a company, why would wireless need to be enabled weekends if no one is there working? 
Or think of an accesspoint in your kids room when you want the youngsters to sleep after 10 pm instead of facebooking...

## Configuration
You can create an arbitrary number of schedule events. WiFi remains allowed while
any enabled time window is active. An overnight window belongs to its starting
weekday; its stop occurs the following day, including Sunday-to-Monday rollover.
Times may use one or two digits for hours and minutes. If start and stop time are
equal, the entry is a stop-only event and does not create an allow window.

Scheduled jobs recheck the current global setting, entry and force policy before
acting. Deleted or disabled entries cannot act through an old cron job. Force
overrides associated clients, not another active allow window. Manual Start,
Stop and ForceStop commands remain available with scheduling disabled; a pending
manual graceful stop retains that ownership when it rechecks.

Package upgrades rebuild cron jobs using current section identities without
changing radio state. Explicit pending rechecks survive and revalidate their
owners when they run. Legacy retries without an owner are discarded.

Logging if enabled is done to the file `/var/log/wifi_schedule.log` and can be reviewed through the "View Logfile" tab.
The cron jobs created can be reviewed through the "View Cron Jobs" tab.

Please note that the "Unload Modules" function is currently considered as experimental. You can manually add / remove modules in the text field.
The button "Determine Modules Automatically" tries to make a best guess determining regarding the driver module and its dependencies.
When un-/loading the modules, there is a certain number of retries (`module_load`) performed.

The option "Force disabling wifi even if stations associated" does what it says - when activated it simply shuts down WiFi.
When unchecked, its checked every `recheck_interval` minutes if there are still stations associated. Once the stations disconnect, WiFi is disabled. To ignore associated stations add their MAC to `ignore_stations`.

Please note, that the parameters `module_load`, `recheck_interval` and `ignore_stations` are only accessible through uci.

## UCI Configuration `wifi_schedule`
UCI configuration file: `/etc/config/wifi_schedule`:

```
config global
        option logging '0'
        option enabled '0'
        option recheck_interval '10'
        option modules_retries '10'
#       option ignore_stations 'AA:AA:AA:AA:AA:AA BB:BB:BB:BB:BB:BB'

config entry 'Businesshours'
        option enabled '0'
        option daysofweek 'Monday Tuesday Wednesday Thursday Friday'
        option starttime '06:00'
        option stoptime '22:00'
        option forcewifidown '0'

config entry 'Weekend'
        option enabled '0'
        option daysofweek 'Saturday Sunday'
        option starttime '00:00'
        option stoptime '00:00'
        option forcewifidown '1'
```

## Script: `wifi_schedule.sh`
This is the script that does the work. Make your changes to the UCI config file: `/etc/config/wifi_schedule`

Then call the script as follows in order to get the necessary cron jobs created:

`wifi_schedule.sh cron`

All commands:
 
```
wifi_schedule.sh cron|cron-only|start|startup|stop|forcestop|recheck|getmodules|savemodules|help

    cron: Create cronjob entries.
    cron-only: Rebuild cron jobs without changing the current radio state.
    start: Start wifi.
    startup: Checks current timewindow and enables/disables WIFI accordingly.
    stop: Stop wifi gracefully, i.e. check if there are stations associated and if so keep retrying.
    forcestop: Stop wifi immediately.
    recheck: Recheck if wifi can be disabled now.
    getmodules: Returns a list of modules used by the wireless driver(s)
    savemodules: Saves a list of automatic determined modules to UCI
    help: This description.
```

## Startup Script: `/etc/init.d/wifi_schedule`
Makes sure time window is checked and WIFI is enabled or disabled accordingly when powering on the router.

## Tests

Run the pure time/day boundary cases with `busybox ash tests/time.sh`. The public
CLI cases run through `sh tests/run-dispatch.sh IMAGE`, where IMAGE supplies Bash,
Python 3 and standard text tools. The runner mounts the product files unchanged
and substitutes external commands in a container without network access; it
cannot modify host or router radios, UCI, crontabs or locks.
