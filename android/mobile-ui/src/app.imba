import * as model from './model.mjs'
import {ui,data} from './model.mjs'
import {mountIntro} from './intro.mjs'

tag halle-intro
	prop active
	prop engaged
	def mount
		self.stopIntro = mountIntro(self)
	def unmount
		if self.stopIntro
			self.stopIntro!
	<self data-active=active data-engaged=engaged>


tag halle-meetings
	prop items
	<self>
		if !items.length
			<p.empty> 'Tu día tiene espacio. Graba una idea cuando aparezca.'
		for item in items
			<article.meeting key=item.id>
				<time> item.time
				<div.meeting-body>
					<button.meeting-title @click=model.openMeeting(item)> item.title
					<p.project-label> item.project || 'Sin proyecto'
					<p.meeting-status data-recording=(item.status == 'RECORDING')> model.transferText(item.transferState) || model.statusText(item)
				<button.trash-button aria-label="Eliminar {item.title}" disabled=(item.status == 'RECORDING' || item.status == 'STARTING') @click=model.askDelete(item)> '×'

tag halle-project-picker
	<self>
		<label.field>
			<span> 'Proyecto'
			<select bind=ui.project @change=model.selectProject>
				<option value=''> 'Sin proyecto'
				for project in data.projects
					<option value=project> project
		<button.text-button @click=(ui.newProject = true)> '+ Nuevo proyecto'

tag halle-app
	def go page
		model.navigate(page)
		if page == 'calendar'
			model.requestRange!
	def dayLabel key
		model.parseDate(key).getDate!
	def prettyDate
		model.parseDate(ui.date).toLocaleDateString('es-CL',{weekday:'long',day:'numeric',month:'long'})
	def monthLabel
		model.parseDate(ui.date).toLocaleDateString('es-CL',{month:'long',year:'numeric'})
	def cancelDelete
		ui.pendingDelete = null
	def dismiss
		ui.message = ''
	def back
		model.navigate(ui.returnPage)
	def showProject
		ui.newProject = true
	def cancelProject
		ui.newProject = false
	def calendar
		ui.date = data.today
		go('calendar')
		model.requestRange!

	<self data-recording=model.recording!>
		if data.preview
			<p.preview-label> 'Vista de prueba · datos de ejemplo'
		if data.error
			<p.error role='alert'> data.error
		<main>
			if ui.page == 'home' || ui.page == 'record'
				<section.orbit-hero data-idle-home=(ui.page == 'home' && !data.active && !ui.starting) data-capturing=(data.active || ui.starting)>
					<p.eyebrow> data.today && model.parseDate(data.today).toLocaleDateString('es-CL',{weekday:'long',day:'numeric',month:'long'})
					<h1> 'Deja fluir las ideas.'
					<halle-intro active=model.recording! engaged=(data.active != null || ui.starting)>
					<div.capture-readout>
						if data.active || ui.starting
							<span.capture-clock role='timer' aria-label='Duración de la grabación'> if data.active then model.duration(data.active.elapsedMs) else '00:00'
							<span.capture-state role='status'> if model.recording! then 'Grabando' else 'Activando micrófono…'
						elif ui.page == 'record' && (ui.captureOutcome == 'discarded_short' || model.chosen! && model.chosen!.discardedRecordingAtMs)
							<span.capture-state role='status'> if (model.chosen! ? model.chosen!.discardCleanupPending : ui.discardCleanupPending) then 'Eliminando grabación…' else 'Grabación descartada'
						elif ui.page == 'record' && model.chosen!
							<span.capture-state> 'Grabación guardada'
						else
							<span.capture-state> 'Tu voz aquí. Tus notas en el Mac.'
					if data.active
						<button.hero-record.tech-record data-active=model.recording! disabled=!model.recording! @click=model.stop!>
							<span.record-glyph aria-hidden='true'>
							<span> 'Terminar grabación'
							<span.record-channel aria-hidden='true'> 'REC'
					else
						<button.hero-record.tech-record aria-label='Grabar ahora' disabled=ui.starting @click=model.quickRecord!>
							<span.record-glyph aria-hidden='true'>
							<span> if ui.starting then 'Activando…' else 'Grabar'
							<span.record-channel aria-hidden='true'> 'MIC'
				if ui.page == 'record' || data.active
					if model.chosen!
						if model.chosen!.error && !model.chosen!.discardedRecordingAtMs
							<p.error role='alert'> model.chosen!.error
						<div.record-project>
							<halle-project-picker>
						if !data.active
							<div.notice role='status'>
								if model.chosen!.discardedRecordingAtMs
									<strong> 'Reunión programada conservada'
									<p> if model.chosen!.discardCleanupPending then 'La grabación duró menos de 10 segundos. Su eliminación está pendiente; no se enviará al Mac.' else 'La grabación duró menos de 10 segundos y se eliminó. Puedes volver a grabar esta reunión.'
								else
									<strong> model.transferText(model.chosen!.transferState) || model.statusText(model.chosen!)
									<p> 'El audio se conserva hasta que tu Mac confirme la transcripción guardada y verificada.'
				else
					<section.today-section>
						<div.section-heading>
							<h2> 'Reuniones de hoy'
							<button.text-button @click=calendar> 'Ver calendario →'
						<halle-meetings items=model.meetingsFor(data.today)>
			elif ui.page == 'calendar'
				<p.eyebrow> 'Tu tiempo'
				<h1> 'Calendario'
				<div.segmented aria-label='Vista del calendario'>
					<button aria-pressed=(ui.calendarView == 'month') @click=model.setView('month')> 'Mes'
					<button aria-pressed=(ui.calendarView == 'week') @click=model.setView('week')> 'Semana'
				<div.calendar-toolbar>
					<button aria-label='Período anterior' @click=model.movePeriod(-1)> '‹'
					<h2> monthLabel!
					<button aria-label='Período siguiente' @click=model.movePeriod(1)> '›'
				<div.calendar-grid data-view=ui.calendarView>
					for label in ['L','M','M','J','V','S','D']
						<span.day-label> label
					for key in (ui.calendarView == 'month' ? model.daysOfMonth(ui.date) : model.weekDates(ui.date))
						if key
							<button.calendar-day data-selected=(key == ui.date) data-events=(model.meetingsFor(key).length > 0) aria-label=model.nice(key) aria-pressed=(key == ui.date) @click=model.selectDate(key)> dayLabel(key)
						else
							<span>
				<div.section-heading>
					<h2> model.nice(ui.date)
					<button.icon-button aria-label='Crear reunión' @click=model.beginSchedule!> '+'
				<halle-meetings items=model.meetingsFor(ui.date)>
			elif ui.page == 'detail'
				if model.chosen!
					<button.text-button @click=back> '← Volver'
					<p.eyebrow> model.nice(model.chosen!.date)
					<h1> model.chosen!.title
					<p.hero-caption> model.chosen!.project || 'Sin proyecto'
					<div.notice role='status'> model.transferText(model.chosen!.transferState) || model.statusText(model.chosen!)
					if model.chosen!.status == 'DRAFT'
						<button.primary @click=model.recordExisting!> 'Grabar esta reunión'
					if model.chosen!.hasMeetingUrl
						<button.secondary @click=model.send('join',{id:ui.detailId})> 'Abrir llamada'
					<button.secondary @click=model.send('note',{id:ui.detailId})> 'Nota local'
					if !model.chosen!.calendar
						<label.field>
							<span> 'Nombre'
							<input type='text' maxlength='160' bind=ui.title>
						<halle-project-picker>
						<button.secondary @click=model.saveDetails!> 'Guardar detalles'
						if model.chosen!.hasAudio
							<button.secondary @click=model.send('play',{id:ui.detailId})> 'Escuchar audio'
							<button.secondary @click=model.send('shareAudio',{id:ui.detailId})> 'Compartir audio'
					<button.danger-quiet @click=model.askDelete(model.chosen!)> 'Mover a la papelera'
			elif ui.page == 'schedule'
				<button.text-button @click=go('calendar')> '← Calendario'
				<p.eyebrow> 'Nueva reunión'
				<h1> 'Hazle espacio.'
				<label.field>
					<span> 'Nombre · opcional'
					<input type='text' maxlength='160' placeholder='Nueva reunión' bind=ui.title>
				<halle-project-picker>
				<div.form-row>
					<label.field>
						<span> 'Fecha'
						<input type='date' bind=ui.scheduledDate required>
					<label.field>
						<span> 'Hora'
						<input type='time' bind=ui.scheduledTime required>
				<button.primary @click=model.schedule!> 'Crear reunión'
			elif ui.page == 'projects'
				<p.eyebrow> 'Todo en su lugar'
				<h1> 'Proyectos'
				<p.hero-caption> 'Cada conversación en su contexto.'
				for project in data.projects
					<div.project-row>
						<span> project
						<span.muted> "{data.meetings.filter(do(m) m.project == project).length} reuniones"
				<button.secondary @click=showProject> '+ Nuevo proyecto'
			elif ui.page == 'settings'
				<p.eyebrow> 'Tu espacio'
				<h1> 'Ajustes'
				<button.settings-row @click=model.send('pair')>
					<span> if data.paired then 'Dispositivos vinculados' else 'Vincular tu Mac'
					<span.muted> '→'
				<button.settings-row @click=model.send('chooseMac')>
					<span> 'Mac para transcripciones'
					<span.muted> 'Elegir →'
				<button.settings-row @click=model.send('calendarAccess')>
					<span> if data.calendarPermission then 'Calendarios seleccionados' else 'Conectar calendario'
					<span.muted> '→'
				<button.settings-row @click=model.send('reminders')>
					<span> 'Avisos · {data.reminderMinutes} min antes'
					<span.muted> '→'
				if !data.notificationsAllowed
					<button.settings-row @click=model.send('notifications')> 'Activar notificaciones'
				<button.settings-row @click=model.send('retryTransfers')>
					<span> 'Reintentar envíos pendientes'
					<span.muted> '↻'
				<button.settings-row @click=model.send('exactAlarms')>
					<span> 'Precisión de recordatorios'
					<span.muted> '→'
				<button.settings-row @click=model.send('trashList')>
					<span> 'Papelera'
					<span.muted> 'Restaurar →'
				<div.notice>
					<strong> 'Tu voz se queda contigo'
					<p> 'El audio viaja cifrado a tu Mac. Se elimina de ambos dispositivos solo después de guardar y verificar el texto.'
					<p> 'Las nuevas grabaciones empiezan en este teléfono. Cambiar de dispositivo en una sesión compartida requiere abrir Dispositivos vinculados.'
		if ui.deleted.length
			<div.undo-bar role='status'>
				<span> 'Reunión en la papelera'
				<button @click=model.undo!> 'Deshacer'
		if ui.message
			<div.message role='status'>
				<span> ui.message
				<button aria-label='Cerrar aviso' @click=dismiss> '×'
		<nav.bottom-nav aria-label='Navegación principal'>
			<button data-selected=(ui.page == 'home' || ui.page == 'record') @click=go('home')>
				<span.nav-icon aria-hidden='true'> '⌂'
				<span> 'Inicio'
			<button data-selected=(ui.page == 'calendar') @click=go('calendar')>
				<span.nav-icon aria-hidden='true'> '▦'
				<span> 'Calendario'
			<button data-selected=(ui.page == 'projects') @click=go('projects')>
				<span.nav-icon aria-hidden='true'> '◇'
				<span> 'Proyectos'
			<button data-selected=(ui.page == 'settings') @click=go('settings')>
				<span.nav-icon aria-hidden='true'> '☷'
				<span> 'Ajustes'
		if ui.pendingDelete
			<div.modal-backdrop>
				<section.dialog role='dialog' aria-modal='true' aria-label='Eliminar reunión'>
					<h2> '¿Mover a la papelera?'
					<p> ui.pendingDelete.title
					<p.muted> 'Se oculta en este teléfono. Conservamos sus archivos para que puedas restaurarla. El evento del calendario original no se elimina.'
					<button.danger @click=model.deleteMeeting!> 'Mover a la papelera'
					<button.secondary @click=cancelDelete> 'Conservar reunión'
		if ui.newProject
			<div.modal-backdrop>
				<section.dialog role='dialog' aria-modal='true' aria-label='Nuevo proyecto'>
					<h2> 'Nuevo proyecto'
					<label.field>
						<span> 'Nombre del proyecto'
						<input type='text' maxlength='80' bind=ui.projectName>
					<button.primary @click=model.createProject!> 'Crear proyecto'
					<button.secondary @click=cancelProject> 'Cancelar'

const app = <halle-app>
imba.mount app, document.getElementById('app')
model.connect do
	app.commit!
model.start!
