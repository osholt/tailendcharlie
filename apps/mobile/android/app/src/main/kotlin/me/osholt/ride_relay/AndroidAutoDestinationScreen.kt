package me.osholt.ride_relay

import androidx.car.app.CarContext
import androidx.car.app.CarToast
import androidx.car.app.Screen
import androidx.car.app.model.Action
import androidx.car.app.model.Header
import androidx.car.app.model.ItemList
import androidx.car.app.model.Row
import androidx.car.app.model.SearchTemplate
import androidx.car.app.model.Template

/**
 * "Where to?" on the head unit.
 *
 * The phone has answered `searchDestinations` and `planDestination` since CarPlay
 * needed them; Android Auto never asked (#602). Nothing new is computed here —
 * the geocoder, the router and the wording of every refusal stay on the phone, so
 * the two projected surfaces cannot drift.
 *
 * Solo is the assumption, as it is on the phone since #600: `groupRide` is left
 * unset rather than sent as false, so the phone applies its own default and a
 * rider who only wants directions is never asked about a ride.
 */
internal class AndroidAutoDestinationScreen(carContext: CarContext) : Screen(carContext) {
    private var results: List<ProjectedRideChannel.Destination> = emptyList()
    private var message: String? = null
    private var searching = false

    override fun onGetTemplate(): Template {
        val builder = SearchTemplate.Builder(
            object : SearchTemplate.SearchCallback {
                override fun onSearchSubmitted(searchText: String) {
                    search(searchText)
                }

                // Deliberately not implemented. Nominatim's usage policy forbids
                // autocomplete against the public API, which is why the phone
                // searches on submit too — `home_destination_search.dart` says
                // so at length. A head unit is not the place to break that.
                override fun onSearchTextChanged(searchText: String) = Unit
            },
        )
            .setHeaderAction(Action.BACK)
            .setShowKeyboardByDefault(true)
            .setSearchHint("Town, postcode, or a place")
        if (searching) builder.setLoading(true) else builder.setItemList(itemList())
        return builder.build()
    }

    private fun itemList(): ItemList {
        val list = ItemList.Builder()
        val note = message
        if (note != null) {
            list.addItem(Row.Builder().setTitle(note).build())
        } else if (results.isEmpty()) {
            list.addItem(
                Row.Builder()
                    .setTitle("Search for somewhere to ride to")
                    .build(),
            )
        }
        // The host refuses a longer list by throwing, and a rider at a head unit
        // reads the top few and stops.
        results.take(MAX_RESULTS).forEach { destination ->
            list.addItem(
                Row.Builder()
                    .setTitle(destination.label)
                    .setBrowsable(false)
                    .setOnClickListener { plan(destination) }
                    .build(),
            )
        }
        return list.build()
    }

    private fun search(query: String) {
        if (query.isBlank()) return
        searching = true
        message = null
        invalidate()
        ProjectedRideChannel.searchDestinations(query) { found, error ->
            searching = false
            results = found
            message = when {
                error != null -> error
                found.isEmpty() -> "Nothing found for “$query”."
                else -> null
            }
            invalidate()
        }
    }

    private fun plan(destination: ProjectedRideChannel.Destination) {
        ProjectedRideChannel.planDestination(destination, groupRide = null) { error ->
            if (error == null) {
                // Back to the map, which is where the route will appear.
                screenManager.pop()
            } else {
                CarToast.makeText(carContext, error, CarToast.LENGTH_LONG).show()
            }
        }
    }

    private companion object {
        const val MAX_RESULTS = 6
    }
}
